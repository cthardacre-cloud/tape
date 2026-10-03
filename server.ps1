# Tape local server. Serves the site and sends market photos to SpaceXAI.
# The API key stays in .env on this PC. Run start.cmd, or:
#   powershell -NoProfile -ExecutionPolicy Bypass -File server.ps1

param(
  [switch]$NoBrowser,
  [int]$Port = 8787
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::Expect100Continue = $false

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) { $Root = (Get-Location).Path }
$Public = Join-Path $Root 'public'
$EnvFile = Join-Path $Root '.env'
$Model = 'grok-4.7'

function Read-Text([string]$Path) {
  $text = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding $false))
  return $text.TrimStart([char]0xFEFF).Trim()
}

$script:Prompt = Read-Text (Join-Path $Root 'prompt.txt')
$schemaRaw = Read-Text (Join-Path $Root 'schema.json')
$null = $schemaRaw | ConvertFrom-Json
if ($schemaRaw -notmatch 'additionalProperties') { throw 'schema.json is missing additionalProperties.' }
$script:SchemaJson = ($schemaRaw | ConvertFrom-Json | ConvertTo-Json -Depth 30 -Compress)
if ($script:SchemaJson -notmatch 'y_percent') { throw 'schema.json did not survive JSON conversion.' }

function Import-DotEnv {
  if (-not (Test-Path $EnvFile)) { return }
  foreach ($line in [IO.File]::ReadAllLines($EnvFile)) {
    if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
      $name = $Matches[1]
      $val = $Matches[2].Trim()
      if ($val.Length -ge 2) {
        $a = $val.Substring(0, 1)
        $b = $val.Substring($val.Length - 1, 1)
        if (($a -eq '"' -and $b -eq '"') -or ($a -eq "'" -and $b -eq "'")) {
          $val = $val.Substring(1, $val.Length - 2)
        }
      }
      Set-Item -Path "Env:$name" -Value $val
    }
  }
}

function Get-ApiKey {
  Import-DotEnv
  return ([string]$env:XAI_API_KEY).Trim()
}

function Save-ApiKey([string]$Key) {
  $clean = $Key.Trim()
  if ($clean.Length -eq 0) {
    $env:XAI_API_KEY = ''
    if (Test-Path $EnvFile) { Remove-Item $EnvFile -Force }
    return
  }
  if ($clean.Length -lt 12 -or $clean.Length -gt 300 -or $clean -match '\s') {
    throw 'That key does not look usable. Paste the full key from console.x.ai.'
  }
  $env:XAI_API_KEY = $clean
  [IO.File]::WriteAllText($EnvFile, "XAI_API_KEY=$clean`r`n", (New-Object Text.UTF8Encoding $false))
}

function Json-String([string]$Value) {
  if ($null -eq $Value) { $Value = '' }
  return ($Value | ConvertTo-Json -Compress)
}

function Write-Bytes($Ctx, [int]$Code, [byte[]]$Bytes, [string]$ContentType) {
  $res = $Ctx.Response
  $res.StatusCode = $Code
  $res.KeepAlive = $false
  $res.ContentType = $ContentType
  $res.Headers['Cache-Control'] = 'no-store'
  $res.ContentLength64 = $Bytes.Length
  $res.OutputStream.Write($Bytes, 0, $Bytes.Length)
  $res.OutputStream.Close()
  $script:Sent = $true
}

function Write-Json($Ctx, [int]$Code, $Obj) {
  $json = $Obj | ConvertTo-Json -Depth 8 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  Write-Bytes $Ctx $Code $bytes 'application/json; charset=utf-8'
}

function Write-TextError($Ctx, [int]$Code, [string]$Message, [string]$ErrorCode) {
  $payload = @{ error = $Message }
  if ($ErrorCode) { $payload.code = $ErrorCode }
  Write-Json $Ctx $Code $payload
}

function Get-PublicFile([string]$UrlPath) {
  $rel = [Uri]::UnescapeDataString(($UrlPath -split '\?')[0])
  if ([string]::IsNullOrWhiteSpace($rel) -or $rel -eq '/') { $rel = '/index.html' }
  $rel = $rel.TrimStart('/').Replace('/', '\')
  if ($rel.Contains('..')) { return $null }
  $full = [IO.Path]::GetFullPath((Join-Path $Public $rel))
  $root = [IO.Path]::GetFullPath($Public)
  if (-not $root.EndsWith('\')) { $root = $root + '\' }
  if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $null }
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
  return $full
}

function Get-ContentType([string]$Path) {
  switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    '.html' { 'text/html; charset=utf-8' }
    '.css' { 'text/css; charset=utf-8' }
    '.js' { 'text/javascript; charset=utf-8' }
    '.svg' { 'image/svg+xml' }
    '.png' { 'image/png' }
    '.jpg' { 'image/jpeg' }
    '.jpeg' { 'image/jpeg' }
    default { 'application/octet-stream' }
  }
}

function Read-Body($Req) {
  $ms = New-Object IO.MemoryStream
  $buffer = New-Object byte[] 65536
  $total = 0
  $limit = 9000000
  while (($n = $Req.InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
    $total += $n
    if ($total -gt $limit) { throw 'The photo is too large. Crop it to the chart and try again.' }
    $ms.Write($buffer, 0, $n)
  }
  $Req.InputStream.Close()
  return [Text.Encoding]::UTF8.GetString($ms.ToArray())
}

function Clip([string]$Value, [int]$Max) {
  if ($null -eq $Value) { return '' }
  $text = ($Value -replace '[\u0000-\u001F]', ' ').Trim()
  if ($text.Length -gt $Max) { return $text.Substring(0, $Max) }
  return $text
}

function As-StringList($Value, [int]$MaxItems) {
  $out = @()
  foreach ($item in @($Value)) {
    if ($null -eq $item) { continue }
    $text = Clip ([string]$item) 240
    if ($text.Length -gt 0) { $out += $text }
    if ($out.Count -ge $MaxItems) { break }
  }
  return ,$out
}

function Normalize-Order($Order) {
  $price = ''
  $kind = 'none'
  $why = ''
  if ($Order) {
    $price = Clip ([string]$Order.price) 40
    $kind = [string]$Order.order
    $why = Clip ([string]$Order.why) 240
  }
  if ($kind -notin @('market', 'limit', 'stop', 'none')) { $kind = 'none' }
  if ($price.Length -eq 0) { $kind = 'none' }
  return @{ price = $price; order = $kind; why = $why }
}

function Normalize-Read($Obj) {
  if (-not $Obj) { throw 'The read came back empty.' }
  $bias = [string]$Obj.bias
  if ($bias -notin @('buy', 'sell', 'wait')) { $bias = 'wait' }
  $timing = [string]$Obj.timing
  if ($timing -notin @('now', 'wait_for_price', 'after_close', 'stay_out')) { $timing = 'stay_out' }
  $confidence = 0
  try { $confidence = [int]$Obj.confidence } catch { $confidence = 0 }
  if ($confidence -lt 0) { $confidence = 0 }
  if ($confidence -gt 100) { $confidence = 100 }

  $levels = @()
  foreach ($level in @($Obj.chart_levels)) {
    if (-not $level) { continue }
    $kind = [string]$level.kind
    if ($kind -notin @('buy', 'sell', 'stop', 'price')) { continue }
    $price = Clip ([string]$level.price) 40
    if ($price.Length -eq 0) { continue }
    $y = 0.0
    try { $y = [double]$level.y_percent } catch { continue }
    if ($y -lt 0) { $y = 0 }
    if ($y -gt 100) { $y = 100 }
    $levels += @{ kind = $kind; price = $price; y_percent = $y }
    if ($levels.Count -ge 4) { break }
  }

  $stopPrice = ''
  $stopWhy = ''
  if ($Obj.stop) {
    $stopPrice = Clip ([string]$Obj.stop.price) 40
    $stopWhy = Clip ([string]$Obj.stop.why) 240
  }

  return @{
    readable = [bool]$Obj.readable
    instrument = (Clip ([string]$Obj.instrument) 60)
    timeframe = (Clip ([string]$Obj.timeframe) 40)
    bias = $bias
    timing = $timing
    confidence = $confidence
    headline = (Clip ([string]$Obj.headline) 220)
    when_to_act = (Clip ([string]$Obj.when_to_act) 600)
    last_price = (Clip ([string]$Obj.last_price) 40)
    buy = (Normalize-Order $Obj.buy)
    sell = (Normalize-Order $Obj.sell)
    stop = @{ price = $stopPrice; why = $stopWhy }
    invalid_if = (Clip ([string]$Obj.invalid_if) 300)
    what_i_see = (As-StringList $Obj.what_i_see 4)
    risks = (As-StringList $Obj.risks 3)
    chart_levels = @($levels)
  }
}

function Get-OutputText($ResponseObj) {
  if ($ResponseObj.output_text) { return [string]$ResponseObj.output_text }
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($ResponseObj.output)) {
    if (-not $item) { continue }
    if ([string]$item.type -ne 'message') { continue }
    foreach ($part in @($item.content)) {
      if ($part -and [string]$part.type -eq 'output_text' -and $part.text) {
        $parts.Add([string]$part.text)
      }
    }
  }
  return ($parts -join '')
}

function Convert-ModelObject([string]$Text) {
  $t = $Text.Trim()
  if ($t.StartsWith('```')) {
    $t = [regex]::Replace($t, '^```(?:json)?\s*', '')
    $t = [regex]::Replace($t, '\s*```$', '')
  }
  $obj = $t | ConvertFrom-Json
  if ($obj -is [string]) { $obj = ($obj | ConvertFrom-Json) }
  return $obj
}

function Build-RequestBody([string]$DataUri, [string]$UserText, [bool]$WithSystem, [bool]$WithReasoning) {
  $image = Json-String $DataUri
  $user = Json-String $UserText
  $system = Json-String $script:Prompt
  $messages = ''
  if ($WithSystem) {
    $messages = '[{"role":"system","content":[{"type":"input_text","text":' + $system + '}]},{"role":"user","content":[{"type":"input_image","image_url":' + $image + ',"detail":"high"},{"type":"input_text","text":' + $user + '}]}]'
  } else {
    $joined = Json-String ($script:Prompt + "`n`n" + $UserText)
    $messages = '[{"role":"user","content":[{"type":"input_image","image_url":' + $image + ',"detail":"high"},{"type":"input_text","text":' + $joined + '}]}]'
  }
  $extra = ''
  if ($WithReasoning) { $extra = ',"reasoning":{"effort":"medium"},"store":false' }
  return '{"model":"' + $Model + '"' + $extra + ',"input":' + $messages + ',"text":{"format":{"type":"json_schema","name":"market_read","strict":true,"schema":' + $script:SchemaJson + '}}}'
}

function Get-Failure($Err) {
  $code = 0
  $detail = ''
  try { $code = [int]$Err.Exception.Response.StatusCode } catch { $code = 0 }
  if ($Err.ErrorDetails -and $Err.ErrorDetails.Message) { $detail = [string]$Err.ErrorDetails.Message }
  if ([string]::IsNullOrWhiteSpace($detail) -and $Err.Exception.Response) {
    try {
      $stream = $Err.Exception.Response.GetResponseStream()
      if ($stream) {
        $reader = New-Object IO.StreamReader($stream)
        $detail = $reader.ReadToEnd()
        $reader.Close()
      }
    } catch { $detail = '' }
  }
  if ([string]::IsNullOrWhiteSpace($detail)) { $detail = [string]$Err.Exception.Message }
  return @{ Code = $code; Body = $detail }
}

function Invoke-Xai([string]$Body, [string]$Key) {
  try {
    $response = Invoke-WebRequest -Uri 'https://api.x.ai/v1/responses' -Method POST -Body $Body -ContentType 'application/json' -Headers @{ Authorization = "Bearer $Key"; 'User-Agent' = 'Tape/1.0' } -TimeoutSec 120 -UseBasicParsing
    return @{ Ok = $true; Code = [int]$response.StatusCode; Body = [string]$response.Content }
  } catch {
    $info = Get-Failure $_
    $detail = [string]$info.Body
    if ($Key -and $detail) { $detail = $detail.Replace($Key, '[key]') }
    if ($detail.Length -gt 800) { $detail = $detail.Substring(0, 800) }
    [Console]::Error.WriteLine(("xai http=" + $info.Code))
    return @{ Ok = $false; Code = [int]$info.Code; Body = $detail }
  }
}

function Get-DataUri([string]$Image) {
  if ([string]::IsNullOrWhiteSpace($Image)) { throw 'Take a photo or upload a screenshot first.' }
  $comma = $Image.IndexOf(',')
  if ($comma -lt 1 -or -not $Image.Substring(0, $comma).StartsWith('data:image/')) {
    throw 'That file is not a photo Tape can read.'
  }
  $b64 = ($Image.Substring($comma + 1) -replace '\s', '')
  if ($b64.Length -gt 8000000) { throw 'The photo is too large. Crop it to the chart and try again.' }
  try { $bytes = [Convert]::FromBase64String($b64) } catch { throw 'That photo was cut off. Take it again.' }
  if ($bytes.Length -lt 32) { throw 'That photo is empty.' }
  $isJpeg = ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8 -and $bytes[2] -eq 0xFF)
  $isPng = ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47)
  if (-not $isJpeg -and -not $isPng) { throw 'Use a jpeg or png photo.' }
  $mime = 'image/jpeg'
  if ($isPng) { $mime = 'image/png' }
  return ('data:' + $mime + ';base64,' + $b64)
}

function Invoke-MarketRead([string]$DataUri, [string]$UserText, [string]$Key) {
  $plans = @(
    @{ System = $true; Reasoning = $true },
    @{ System = $false; Reasoning = $false }
  )
  $last = $null
  foreach ($plan in $plans) {
    $body = Build-RequestBody $DataUri $UserText ([bool]$plan.System) ([bool]$plan.Reasoning)
    $result = Invoke-Xai $body $Key
    if ($result.Ok) { return $result.Body }
    $last = $result
    $refused = ($result.Code -eq 401) -or ($result.Body -match 'Incorrect API key|invalid api key|invalid_api_key')
    if ($refused) { throw 'That key was refused. Check it at console.x.ai.' }
    $retry = ($result.Code -ge 400 -and $result.Code -lt 500 -and $result.Code -ne 429)
    if (-not $retry) { break }
  }
  if ($last -and $last.Code -eq 429) { throw 'SpaceXAI is busy. Wait a moment and read the photo again.' }
  if (-not $last -or $last.Code -eq 0) { throw 'Tape could not reach SpaceXAI. Check the connection and try again.' }
  $hint = ''
  if ($last.Body) {
    try {
      $errObj = $last.Body | ConvertFrom-Json
      if ($errObj.error) { $hint = ' ' + (Clip ([string]$errObj.error) 180) }
      elseif ($errObj.message) { $hint = ' ' + (Clip ([string]$errObj.message) 180) }
    } catch {
      $hint = ' ' + (Clip ([string]$last.Body) 180)
    }
  }
  throw ('SpaceXAI could not read that photo.' + $hint)
}

function Handle-Analyze($Ctx) {
  $key = Get-ApiKey
  if ([string]::IsNullOrWhiteSpace($key)) {
    Write-TextError $Ctx 401 'Add a SpaceXAI key first. Tape sends the photo to SpaceXAI to read it.' 'missing_key'
    return
  }
  $raw = Read-Body $Ctx.Request
  try { $payload = $raw | ConvertFrom-Json } catch { throw 'The photo did not arrive in one piece. Try again.' }
  $dataUri = Get-DataUri ([string]$payload.image)
  $horizon = [string]$payload.horizon
  $horizonText = 'The user cares about today.'
  if ($horizon -eq 'minutes') { $horizonText = 'The user cares about the next few minutes.' }
  elseif ($horizon -eq 'week') { $horizonText = 'The user cares about this week.' }
  $symbol = Clip ([string]$payload.symbol) 40
  $note = Clip ([string]$payload.note) 240
  if ($symbol.Length -eq 0) { $symbol = '(none)' }
  if ($note.Length -eq 0) { $note = '(none)' }
  $userText = @"
User context, which does not override the rules:
Horizon: $horizonText
Symbol hint: $symbol
Note: $note
"@.Trim()
  [Console]::Out.WriteLine(('analyze bytes=' + $dataUri.Length))
  $content = Invoke-MarketRead $dataUri $userText $key
  $parsed = $content | ConvertFrom-Json
  $text = Get-OutputText $parsed
  if ([string]::IsNullOrWhiteSpace($text)) { throw 'The read came back empty. Try the photo again.' }
  $modelObj = Convert-ModelObject $text
  $read = Normalize-Read $modelObj
  Write-Json $Ctx 200 @{ model = $Model; read = $read }
}

function Handle-Key($Ctx) {
  $raw = Read-Body $Ctx.Request
  try { $payload = $raw | ConvertFrom-Json } catch { throw 'Could not read that key.' }
  Save-ApiKey ([string]$payload.key)
  $on = -not [string]::IsNullOrWhiteSpace((Get-ApiKey))
  Write-Json $Ctx 200 @{ ok = $true; configured = $on }
}

function Handle-Request($Ctx) {
  $script:Sent = $false
  $req = $Ctx.Request
  $path = $req.Url.AbsolutePath
  $method = $req.HttpMethod
  [Console]::Out.WriteLine(("$method $path"))
  if ($method -eq 'GET' -and $path -eq '/api/status') {
    $on = -not [string]::IsNullOrWhiteSpace((Get-ApiKey))
    Write-Json $Ctx 200 @{ configured = $on; model = $Model }
    return
  }
  if ($method -eq 'POST' -and $path -eq '/api/key') {
    Handle-Key $Ctx
    return
  }
  if ($method -eq 'POST' -and $path -eq '/api/analyze') {
    Handle-Analyze $Ctx
    return
  }
  if ($method -eq 'GET') {
    $file = Get-PublicFile $path
    if (-not $file) {
      Write-TextError $Ctx 404 'Not found.' ''
      return
    }
    $bytes = [IO.File]::ReadAllBytes($file)
    Write-Bytes $Ctx 200 $bytes (Get-ContentType $file)
    return
  }
  Write-TextError $Ctx 405 'That action is not available.' ''
}

function Start-TapeListener([int]$Wanted) {
  for ($p = $Wanted; $p -lt ($Wanted + 15); $p++) {
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:$p/")
    try {
      $listener.Start()
      return @{ Listener = $listener; Port = $p }
    } catch {
      $listener.Close()
    }
  }
  throw "Could not listen on ports $Wanted through $($Wanted + 14)."
}

$started = Start-TapeListener $Port
$Listener = $started.Listener
$LivePort = $started.Port
$Url = "http://127.0.0.1:$LivePort/"
[Console]::Out.WriteLine("TAPE $Url")
[Console]::Out.Flush()
if (-not (Get-ApiKey)) {
  [Console]::Out.WriteLine('No key yet. Paste one in the page, or set XAI_API_KEY in market-tape\.env')
}
if (-not $NoBrowser) { Start-Process $Url }

try {
  while ($Listener.IsListening) {
    $ctx = $null
    try {
      $ctx = $Listener.GetContext()
      $script:Sent = $false
      Handle-Request $ctx
    } catch {
      $message = $_.Exception.Message
      if ($message.Length -gt 300) { $message = $message.Substring(0, 300) }
      [Console]::Error.WriteLine($message)
      if ($ctx -and -not $script:Sent) {
        try { Write-TextError $ctx 500 $message '' } catch {}
      }
    }
  }
} finally {
  if ($Listener.IsListening) { $Listener.Stop() }
  $Listener.Close()
}
