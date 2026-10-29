#Requires -Version 7.0
<#
.SYNOPSIS
    Validador del laboratorio "Operación Rescate".

.DESCRIPTION
    1. Ejecuta peticiones reales contra la API (con identificadores únicos
       generados en CADA ejecución del validador).
    2. Verifica respuestas HTTP, cabecera X-Correlation-ID y errores seguros.
    3. Lee los archivos de la carpeta de logs y comprueba que lo registrado
       corresponde EXACTAMENTE a las peticiones que este script acaba de hacer.
    4. Calcula el puntaje (sobre 100) y la nota (sobre 10).

.EXAMPLE
    .\validar.ps1 -BaseUrl http://localhost:5000 -LogDir .\logs
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://localhost:5000',
    [string]$LogDir = './logs',
    [int]$EsperaLogsMs = 1500,
    [string]$Reporte = './reporte-validacion.json'
)

$ErrorActionPreference = 'Stop'
$script:Base = $BaseUrl.TrimEnd('/')
$script:LogDirPath = $LogDir
$script:RunId = 'run-' + ([guid]::NewGuid().ToString('N').Substring(0, 12))
$script:Canary = 'CANARY-' + [guid]::NewGuid().ToString('N')
$script:GuidRx = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:RxTs = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$'
$script:Niveles = @('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
$script:Resultados = [System.Collections.Generic.List[object]]::new()
$script:Enviadas = [System.Collections.Generic.List[object]]::new()
$script:BizCids = [System.Collections.Generic.List[string]]::new()
$script:ExcCid = $null

$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.UseProxy = $false
$script:Http = [System.Net.Http.HttpClient]::new($handler)
$script:Http.Timeout = [TimeSpan]::FromSeconds(30)

# ----------------------------------------------------------------------------
#  HTTP
# ----------------------------------------------------------------------------
function New-ApiRequest {
    param([string]$Method, [string]$Path, [string]$Body = '', [string[]]$Header = @())
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), "$($script:Base)$Path")
    [void]$req.Headers.TryAddWithoutValidation('X-Lab-Run-Id', $script:RunId)
    foreach ($h in $Header) {
        $i = $h.IndexOf(':')
        [void]$req.Headers.TryAddWithoutValidation($h.Substring(0, $i).Trim(), $h.Substring($i + 1).Trim())
    }
    if (-not [string]::IsNullOrEmpty($Body)) {
        $req.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8, 'application/json')
    }
    return $req
}

function Read-ApiResponse {
    param($Resp)
    $body = $Resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $vals = $null
    $cid = $null
    if ($Resp.Headers.TryGetValues('X-Correlation-ID', [ref]$vals)) { $cid = @($vals)[0] }
    $ct = ''
    if ($null -ne $Resp.Content.Headers.ContentType) { $ct = $Resp.Content.Headers.ContentType.MediaType }
    return [pscustomobject]@{ Status = [int]$Resp.StatusCode; Body = $body; Cid = $cid; ContentType = $ct }
}

function Invoke-Api {
    param([string]$Method, [string]$Path, [string]$Body = '', [string[]]$Header = @())
    try {
        $req = New-ApiRequest -Method $Method -Path $Path -Body $Body -Header $Header
        $resp = $script:Http.SendAsync($req).GetAwaiter().GetResult()
        $r = Read-ApiResponse $resp
        $resp.Dispose()
    }
    catch {
        $r = [pscustomobject]@{ Status = 0; Body = $_.Exception.Message; Cid = $null; ContentType = '' }
    }
    $script:Enviadas.Add([pscustomobject]@{ Method = $Method; Path = ($Path -split '\?')[0]; Status = $r.Status; Cid = $r.Cid })
    return $r
}

function Read-Json {
    param([string]$Texto)
    try { return ($Texto | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Test-Numero { param($v) return ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) }

function Get-Stock {
    param([string]$Sku)
    $r = Invoke-Api GET "/api/inventario/$Sku"
    $j = Read-Json $r.Body
    if ($null -ne $j -and (Test-Numero $j.stock)) { return [long]$j.stock }
    return $null
}

function Get-CuerpoInseguro {
    param([string]$Body)
    $patrones = @('StackTrace', 'stackTrace', 'Fallo simulado', ' at [A-Za-z_][A-Za-z0-9_.<>]*\(', '\.cs[^A-Za-z]',
        'System\.', 'Microsoft\.', '[A-Za-z]:\\', '/home/', '/usr/', '/app/', '/src/', 'Exception')
    foreach ($p in $patrones) {
        if ($Body -cmatch $p) { return "el cuerpo expone información técnica (coincide con '$p')" }
    }
    return $null
}

# Valida una respuesta de error: estado, JSON (problem details), correlationId y seguridad
function Get-ErrorProblem {
    param($R, [int]$Esperado)
    if ($R.Status -ne $Esperado) { return "estado $($R.Status) (esperado $Esperado)" }
    if ($R.ContentType -notmatch 'json') { return "Content-Type '$($R.ContentType)' no es JSON (se espera application/problem+json)" }
    $j = Read-Json $R.Body
    if ($null -eq $j -or $j -isnot [pscustomobject]) { return 'el cuerpo no es un objeto JSON válido' }
    if ($j.status -ne $Esperado) { return "el campo 'status' del cuerpo es '$($j.status)'" }
    if ([string]::IsNullOrEmpty($j.correlationId) -or ($j.correlationId -ine $R.Cid)) {
        return "'correlationId' del cuerpo ('$($j.correlationId)') no coincide con la cabecera X-Correlation-ID ('$($R.Cid)')"
    }
    return (Get-CuerpoInseguro $R.Body)
}

# ----------------------------------------------------------------------------
#  Registro de resultados
# ----------------------------------------------------------------------------
function Invoke-Prueba {
    param([string]$Id, [string]$Nombre, [int]$Puntos, [scriptblock]$Bloque)
    $fallos = [System.Collections.Generic.List[string]]::new()
    try { $null = & $Bloque $fallos } catch { $fallos.Add("error interno del validador: $($_.Exception.Message)") }
    $ok = ($fallos.Count -eq 0)
    $detalle = ($fallos -join '; ')
    $script:Resultados.Add([pscustomobject]@{ Id = $Id; Nombre = $Nombre; Puntos = $Puntos; Ok = $ok; Detalle = $detalle })
    if ($ok) {
        Write-Host ('  [ OK ] {0,-4} {1} ({2} pts)' -f $Id, $Nombre, $Puntos) -ForegroundColor Green
    }
    else {
        Write-Host ('  [FAIL] {0,-4} {1} (0/{2} pts)' -f $Id, $Nombre, $Puntos) -ForegroundColor Red
        Write-Host "         -> $detalle" -ForegroundColor Yellow
    }
}

function Write-Seccion { param([string]$Titulo) Write-Host ''; Write-Host $Titulo -ForegroundColor Cyan }

# ----------------------------------------------------------------------------
#  Lectura de logs
# ----------------------------------------------------------------------------
function ConvertFrom-JsonElement {
    param([System.Text.Json.JsonElement]$El)
    switch ($El.ValueKind.ToString()) {
        'Object' {
            $h = [System.Collections.Generic.Dictionary[string, object]]::new()
            foreach ($p in $El.EnumerateObject()) { $h[$p.Name] = ConvertFrom-JsonElement $p.Value }
            return $h
        }
        'Array' {
            $l = [System.Collections.Generic.List[object]]::new()
            foreach ($x in $El.EnumerateArray()) { $l.Add((ConvertFrom-JsonElement $x)) }
            return , $l
        }
        'String' { return $El.GetString() }
        'Number' { return $El.GetDouble() }
        'True' { return $true }
        'False' { return $false }
        default { return $null }
    }
}

function Read-Logs {
    $eventos = [System.Collections.Generic.List[object]]::new()
    $invalidas = 0; $lineas = 0; $archivos = 0; $sensible = $false
    if (Test-Path -LiteralPath $script:LogDirPath -PathType Container) {
        foreach ($f in (Get-ChildItem -LiteralPath $script:LogDirPath -File -Recurse)) {
            $archivos++
            $fs = [System.IO.File]::Open($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
            try {
                while ($null -ne ($line = $sr.ReadLine())) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    $lineas++
                    if ($line.Contains($script:Canary)) { $sensible = $true }
                    try {
                        $doc = [System.Text.Json.JsonDocument]::Parse($line)
                        try {
                            if ($doc.RootElement.ValueKind.ToString() -eq 'Object') { $eventos.Add((ConvertFrom-JsonElement $doc.RootElement)) }
                            else { $invalidas++ }
                        }
                        finally { $doc.Dispose() }
                    }
                    catch { $invalidas++ }
                }
            }
            finally { $sr.Dispose() }
        }
    }
    return [pscustomobject]@{ Eventos = $eventos; Invalidas = $invalidas; Lineas = $lineas; Archivos = $archivos; Sensible = $sensible }
}

function Get-Prop {
    param($E, [string]$K)
    if ($E -is [System.Collections.Generic.Dictionary[string, object]] -and $E.ContainsKey($K)) { return $E[$K] }
    return $null
}

function Get-EventosPorCid {
    param($Lista, [string]$Cid)
    if ([string]::IsNullOrEmpty($Cid)) { return @() }
    return @($Lista | Where-Object { ([string](Get-Prop $_ 'CorrelationId')) -ieq $Cid })
}

function Get-ProblemasEvento {
    param($E)
    $p = [System.Collections.Generic.List[string]]::new()
    $t = Get-Prop $E 'Timestamp'
    if ($t -isnot [string] -or $t -cnotmatch $script:RxTs) { $p.Add('Timestamp (ISO 8601 UTC terminado en Z)') }
    $l = Get-Prop $E 'Level'
    if ($l -isnot [string] -or ($script:Niveles -cnotcontains $l)) { $p.Add('Level') }
    $m = Get-Prop $E 'MessageTemplate'
    if ($m -isnot [string] -or $m.Length -eq 0) { $p.Add('MessageTemplate') }
    foreach ($k in @('RequestMethod', 'RequestPath', 'CorrelationId', 'LabRunId')) {
        $v = Get-Prop $E $k
        if ($v -isnot [string] -or $v.Length -eq 0) { $p.Add($k) }
    }
    $s = Get-Prop $E 'StatusCode'
    if ($s -isnot [double]) { $p.Add('StatusCode (numérico)') }
    $el = Get-Prop $E 'ElapsedMs'
    if ($el -isnot [double] -or $el -lt 0) { $p.Add('ElapsedMs (numérico >= 0)') }
    return , $p
}

# ============================================================================
Write-Host '============================================================'
Write-Host ' Validador - Operación Rescate'
Write-Host " API:      $($script:Base)"
Write-Host " Logs:     $LogDir"
Write-Host " LabRunId: $($script:RunId)"
Write-Host '============================================================'

$pre = Invoke-Api GET '/api/inventario'
if ($pre.Status -eq 0) {
    Write-Host "No se pudo conectar con $($script:Base). ¿La API está en ejecución y el puerto es correcto?" -ForegroundColor Red
    exit 2
}

# ============================================================================
Write-Seccion '1) Comportamiento de la API'
# ============================================================================

Invoke-Prueba 'T01' 'Consultar inventario existente (200)' 5 {
    param($f)
    $r = Invoke-Api GET '/api/inventario/LAP-001'
    if ($r.Status -ne 200) { $f.Add("estado $($r.Status) (esperado 200)"); return }
    $j = Read-Json $r.Body
    if ($null -eq $j -or ([string]$j.sku).ToUpper() -ne 'LAP-001') { $f.Add('el cuerpo no contiene sku=LAP-001') }
    if ($null -eq $j -or -not (Test-Numero $j.stock)) { $f.Add("el cuerpo no contiene 'stock' numérico") }
}

Invoke-Prueba 'T02' 'Consultar inventario inexistente (404 seguro y consistente)' 5 {
    param($f)
    $r = Invoke-Api GET '/api/inventario/NOEXISTE-999'
    if ($r.Cid) { $script:BizCids.Add($r.Cid) }
    $e = Get-ErrorProblem $r 404
    if ($e) { $f.Add($e) }
}

Invoke-Prueba 'T03' 'Crear pedido válido (201 y descuento de stock)' 6 {
    param($f)
    $s0 = Get-Stock 'LAP-001'
    $ped = '{"clienteId":"CLI-001","password":"' + $script:Canary + '","items":[{"sku":"LAP-001","cantidad":1}]}'
    $r = Invoke-Api POST '/api/pedidos' $ped @("Authorization: Bearer $($script:Canary)")
    if ($r.Status -ne 201) { $f.Add("estado $($r.Status) (esperado 201)"); return }
    $j = Read-Json $r.Body
    if ($null -eq $j -or [string]::IsNullOrEmpty([string]$j.id)) { $f.Add("la respuesta no incluye 'id' del pedido") }
    $s1 = Get-Stock 'LAP-001'
    if ($null -ne $s0 -and $null -ne $s1) {
        if ($s1 -ne ($s0 - 1)) { $f.Add("el stock debía pasar de $s0 a $($s0 - 1) y quedó en $s1") }
    }
    else { $f.Add('no se pudo leer el stock antes/después del pedido') }
}

Invoke-Prueba 'T04' 'Pedido con cantidad cero (400)' 5 {
    param($f)
    $r = Invoke-Api POST '/api/pedidos' '{"clienteId":"CLI-001","items":[{"sku":"LAP-001","cantidad":0}]}'
    if ($r.Cid) { $script:BizCids.Add($r.Cid) }
    $e = Get-ErrorProblem $r 400
    if ($e) { $f.Add($e) }
}

Invoke-Prueba 'T05' 'Pedido con cantidad negativa (400, sin alterar stock)' 3 {
    param($f)
    $s0 = Get-Stock 'LAP-001'
    $r = Invoke-Api POST '/api/pedidos' '{"clienteId":"CLI-001","items":[{"sku":"LAP-001","cantidad":-5}]}'
    if ($r.Cid) { $script:BizCids.Add($r.Cid) }
    $e = Get-ErrorProblem $r 400
    if ($e) { $f.Add($e) }
    $s1 = Get-Stock 'LAP-001'
    if ($null -ne $s0 -and $null -ne $s1 -and $s1 -ne $s0) { $f.Add("una cantidad negativa modificó el stock ($s0 -> $s1)") }
}

Invoke-Prueba 'T06' 'Pedido superior al inventario (409, sin alterar stock)' 6 {
    param($f)
    $ss = Get-Stock 'SSD-005'
    if ($null -eq $ss) { $f.Add('no se pudo leer el stock de SSD-005'); return }
    $cuerpo = '{"clienteId":"CLI-001","items":[{"sku":"SSD-005","cantidad":' + ($ss + 1) + '}]}'
    $r = Invoke-Api POST '/api/pedidos' $cuerpo
    if ($r.Cid) { $script:BizCids.Add($r.Cid) }
    $e = Get-ErrorProblem $r 409
    if ($e) { $f.Add($e) }
    $ss2 = Get-Stock 'SSD-005'
    if ($ss2 -ne $ss) { $f.Add("el pedido rechazado alteró el stock de SSD-005 ($ss -> $ss2)") }
}

Invoke-Prueba 'T07' 'JSON malformado o pedido sin items (400)' 5 {
    param($f)
    $r = Invoke-Api POST '/api/pedidos' '{"clienteId":"CLI-001","items":['
    if ($r.Cid) { $script:BizCids.Add($r.Cid) }
    $e = Get-ErrorProblem $r 400
    if ($e) { $f.Add("JSON malformado: $e") }
    $r = Invoke-Api POST '/api/pedidos' '{"clienteId":"CLI-001","items":[]}'
    if ($r.Cid) { $script:BizCids.Add($r.Cid) }
    $e = Get-ErrorProblem $r 400
    if ($e) { $f.Add("items vacío: $e") }
}

Invoke-Prueba 'T08' 'Pedido con SKU inexistente (404)' 3 {
    param($f)
    $r = Invoke-Api POST '/api/pedidos' '{"clienteId":"CLI-001","items":[{"sku":"NOEXISTE-000","cantidad":1}]}'
    if ($r.Cid) { $script:BizCids.Add($r.Cid) }
    $e = Get-ErrorProblem $r 404
    if ($e) { $f.Add($e) }
}

Invoke-Prueba 'T09' 'Excepción de laboratorio (500 seguro, sin detalles técnicos)' 6 {
    param($f)
    $r = Invoke-Api GET '/api/lab/excepcion'
    $script:ExcCid = $r.Cid
    $e = Get-ErrorProblem $r 500
    if ($e) { $f.Add($e) }
}

# ============================================================================
Write-Seccion '2) Identificador de correlación'
# ============================================================================

Invoke-Prueba 'C01' 'Acepta y devuelve un X-Correlation-ID válido' 4 {
    param($f)
    $g = [guid]::NewGuid().ToString()
    $r = Invoke-Api GET '/api/inventario/MOU-002' '' @("X-Correlation-ID: $g")
    if ($r.Cid -ine $g) { $f.Add("se envió $g y la respuesta devolvió '$($r.Cid)'") }
}

Invoke-Prueba 'C02' 'Reemplaza identificadores malformados por un GUID nuevo' 4 {
    param($f)
    $malos = @("abc-$([guid]::NewGuid())-zzz", ('x' * 300), 'no es un guid; DROP TABLE')
    foreach ($m in $malos) {
        $r = Invoke-Api GET '/api/inventario/MOU-002' '' @("X-Correlation-ID: $m")
        $corto = $m.Substring(0, [Math]::Min(40, $m.Length))
        if ([string]::IsNullOrEmpty($r.Cid) -or $r.Cid -notmatch $script:GuidRx) {
            $f.Add("para '$corto' no se generó un GUID válido (respuesta: '$($r.Cid)')")
        }
        elseif ($r.Cid -ieq $m) { $f.Add("se aceptó un identificador malformado: '$corto'") }
    }
}

Invoke-Prueba 'C03' 'Genera un identificador cuando no llega ninguno' 3 {
    param($f)
    $a1 = (Invoke-Api GET '/api/inventario/MOU-002').Cid
    $a2 = (Invoke-Api GET '/api/inventario/MOU-002').Cid
    if ([string]::IsNullOrEmpty($a1) -or $a1 -notmatch $script:GuidRx) { $f.Add("sin cabecera entrante no se generó un GUID válido ('$a1')") }
    if ([string]::IsNullOrEmpty($a2) -or $a2 -notmatch $script:GuidRx) { $f.Add("segunda petición sin identificador no devolvió un GUID válido ('$a2')") }
    if ([string]::IsNullOrEmpty($a1) -or $a1 -ieq $a2) { $f.Add('dos peticiones distintas recibieron el mismo identificador') }
}

Invoke-Prueba 'C04' 'Peticiones simultáneas conservan su propio identificador' 4 {
    param($f)
    $n = 20
    $tareas = [System.Collections.Generic.List[object]]::new()
    for ($i = 1; $i -le $n; $i++) {
        $cid = [guid]::NewGuid().ToString()
        $p = if ($i % 2 -eq 0) { '/api/inventario/LAP-001' } else { '/api/lab/lento?ms=150' }
        $req = New-ApiRequest -Method GET -Path $p -Header @("X-Correlation-ID: $cid")
        $tareas.Add([pscustomobject]@{ Cid = $cid; Path = ($p -split '\?')[0]; Task = $script:Http.SendAsync($req) })
    }
    try { [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($tareas | ForEach-Object { $_.Task })) } catch { }
    $malos = 0
    foreach ($t in $tareas) {
        $status = 0; $got = $null
        if ($t.Task.Status.ToString() -eq 'RanToCompletion') {
            $r = Read-ApiResponse $t.Task.Result
            $status = $r.Status; $got = $r.Cid
        }
        $script:Enviadas.Add([pscustomobject]@{ Method = 'GET'; Path = $t.Path; Status = $status; Cid = $got })
        if ($status -ne 200 -or $got -ine $t.Cid) { $malos++ }
    }
    if ($malos -gt 0) { $f.Add("$malos de $n peticiones simultáneas no conservaron su propio identificador o no devolvieron 200") }
}

# Peticiones para medir tiempos
$lento1 = (Invoke-Api GET '/api/lab/lento?ms=300').Cid
$lento2 = (Invoke-Api GET '/api/lab/lento?ms=800').Cid
$rapida = (Invoke-Api GET "/api/inventario/MOU-002?token=$($script:Canary)").Cid

# ============================================================================
Write-Seccion '3) Logs estructurados'
# ============================================================================
Start-Sleep -Milliseconds $EsperaLogsMs

$logs = Read-Logs

$ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($e in $script:Enviadas) { if (-not [string]::IsNullOrEmpty($e.Cid)) { [void]$ids.Add($e.Cid) } }

$evSent = [System.Collections.Generic.List[object]]::new()
foreach ($e in $logs.Eventos) {
    $c = Get-Prop $e 'CorrelationId'
    if ($c -is [string] -and $ids.Contains($c)) { $evSent.Add($e) }
}
$comp = @($evSent | Where-Object { $null -ne (Get-Prop $_ 'ElapsedMs') })

Invoke-Prueba 'L01' 'Existen archivos de log con contenido' 3 {
    param($f)
    if ($logs.Archivos -eq 0) { $f.Add("no existen archivos dentro de '$LogDir'") }
    if ($logs.Lineas -eq 0) { $f.Add('los archivos de log están vacíos') }
}

Invoke-Prueba 'L02' 'Formato JSON Lines (un JSON válido por línea)' 3 {
    param($f)
    if ($logs.Lineas -eq 0) { $f.Add('no hay líneas que validar') }
    elseif ($logs.Invalidas -gt 0) { $f.Add("$($logs.Invalidas) línea(s) no son un objeto JSON válido (se exige un evento JSON por línea)") }
}

Invoke-Prueba 'L03' 'Propiedades obligatorias en el evento de finalización' 5 {
    param($f)
    if ($comp.Count -eq 0) { $f.Add('no se encontró ningún evento de finalización (evento con ElapsedMs) de las peticiones ejecutadas'); return }
    $nb = 0; $ejemplo = ''
    foreach ($e in $comp) {
        $p = Get-ProblemasEvento $e
        if ($p.Count -gt 0) { $nb++; if (-not $ejemplo) { $ejemplo = 'campos con problema: ' + ($p -join ', ') } }
    }
    if ($nb -gt 0) { $f.Add("$nb evento(s) de finalización con propiedades ausentes o con tipo/formato incorrecto. Ejemplo: $ejemplo") }
}

$script:NivelFallos = [System.Collections.Generic.List[string]]::new()
Invoke-Prueba 'L04' 'Cada petición ejecutada tiene exactamente un evento de finalización correcto' 8 {
    param($f)
    $nf = 0; $detalles = [System.Collections.Generic.List[string]]::new()
    foreach ($q in $script:Enviadas) {
        $tag = "[$($q.Method) $($q.Path) $($q.Status)]"
        if ([string]::IsNullOrEmpty($q.Cid)) { $nf++; $detalles.Add("$tag la respuesta no trae X-Correlation-ID"); continue }
        $evs = @(Get-EventosPorCid $comp $q.Cid)
        if ($evs.Count -eq 0) { $nf++; $detalles.Add("$tag sin evento de finalización para el id $($q.Cid)"); continue }
        if ($evs.Count -gt 1) { $nf++; $detalles.Add("$tag $($evs.Count) eventos de finalización para el mismo id (duplicado)"); continue }
        $ev = $evs[0]
        $em = [string](Get-Prop $ev 'RequestMethod'); $ep = [string](Get-Prop $ev 'RequestPath')
        $es = Get-Prop $ev 'StatusCode'; $lv = [string](Get-Prop $ev 'Level')
        if ($em -ine $q.Method -or $ep -ine $q.Path -or $es -ne [double]$q.Status) {
            $nf++; $detalles.Add("$tag el log dice '$em $ep $es'")
        }
        $esp = $null
        if ($q.Status -ge 500) { $esp = 'Error' } elseif ($q.Status -ge 400) { $esp = 'Warning' } elseif ($q.Status -ge 200) { $esp = 'Information' }
        if ($esp -and $lv -cne $esp) { $script:NivelFallos.Add("$tag nivel '$lv' (esperado $esp)") }
    }
    if ($nf -gt 0) {
        $txt = ($detalles -join '; ')
        if ($txt.Length -gt 600) { $txt = $txt.Substring(0, 600) }
        $f.Add("$nf petición(es) sin un único evento correcto. $txt")
    }
}

Invoke-Prueba 'L05' 'ElapsedMs refleja el tiempo real de procesamiento' 5 {
    param($f)
    $v = @{}
    foreach ($par in @(@('l1', $lento1), @('l2', $lento2), @('rap', $rapida))) {
        $ev = @(Get-EventosPorCid $comp $par[1])
        $v[$par[0]] = if ($ev.Count -gt 0) { Get-Prop $ev[0] 'ElapsedMs' } else { $null }
    }
    if ($null -eq $v['l1'] -or $null -eq $v['l2'] -or $null -eq $v['rap']) { $f.Add('faltan los eventos de las peticiones de medición de tiempo'); return }
    if ($v['l1'] -lt 250 -or $v['l1'] -gt 10000) { $f.Add("petición de 300 ms registró ElapsedMs=$($v['l1']) (se esperaba entre 250 y 10000)") }
    if ($v['l2'] -lt 700 -or $v['l2'] -gt 15000) { $f.Add("petición de 800 ms registró ElapsedMs=$($v['l2']) (se esperaba >= 700)") }
    if ($v['l2'] -le $v['l1']) { $f.Add("ElapsedMs no refleja la duración real ($($v['l2']) no es mayor que $($v['l1']))") }
    if ($v['l1'] -le $v['rap']) { $f.Add("la petición rápida ($($v['rap']) ms) no es más corta que la lenta ($($v['l1']) ms)") }
}

Invoke-Prueba 'L06' 'LabRunId propagado a todos los eventos de cada petición' 4 {
    param($f)
    if ($evSent.Count -eq 0) { $f.Add('no hay eventos asociados a las peticiones ejecutadas'); return }
    $sinRun = @($evSent | Where-Object { (Get-Prop $_ 'LabRunId') -cne $script:RunId })
    if ($sinRun.Count -gt 0) { $f.Add("$($sinRun.Count) evento(s) de peticiones ejecutadas no incluyen LabRunId=$($script:RunId) (se envía en la cabecera X-Lab-Run-Id)") }
}

Invoke-Prueba 'L07' "Excepción registrada una sola vez; errores de negocio no son 'Error'" 6 {
    param($f)
    if ([string]::IsNullOrEmpty($script:ExcCid)) { $f.Add('la excepción de laboratorio no devolvió X-Correlation-ID') }
    else {
        $evExc = @(Get-EventosPorCid $evSent $script:ExcCid)
        $conExc = @($evExc | Where-Object { $x = Get-Prop $_ 'Exception'; $x -is [string] -and $x.Length -gt 0 })
        if ($conExc.Count -eq 0) { $f.Add("no hay ningún evento con la propiedad 'Exception' para la excepción de laboratorio") }
        elseif ($conExc.Count -gt 1) { $f.Add("la misma excepción se registró $($conExc.Count) veces con detalle de Exception (duplicada)") }
        else {
            $texto = [string](Get-Prop $conExc[0] 'Exception')
            if (-not $texto.Contains('Fallo simulado')) { $f.Add('la propiedad Exception no conserva el mensaje/traza real del error') }
        }
        $cev = @(Get-EventosPorCid $comp $script:ExcCid)
        $lvl = if ($cev.Count -gt 0) { [string](Get-Prop $cev[0] 'Level') } else { '' }
        if ($lvl -cne 'Error') { $f.Add("el evento de finalización de la excepción tiene nivel '$lvl' (esperado Error)") }
    }
    $nbiz = 0
    foreach ($c in $script:BizCids) {
        $malos = @(Get-EventosPorCid $evSent $c | Where-Object { (Get-Prop $_ 'Level') -in @('Error', 'Fatal') })
        if ($malos.Count -gt 0) { $nbiz++ }
    }
    if ($nbiz -gt 0) { $f.Add("$nbiz error(es) de negocio (400/404/409) se registraron con nivel Error/Fatal como si fueran excepciones internas") }
}

Invoke-Prueba 'L08' 'Los logs no contienen datos sensibles' 4 {
    param($f)
    if ($logs.Lineas -eq 0) { $f.Add('no hay logs que revisar') }
    elseif ($logs.Sensible) { $f.Add('se encontró información sensible enviada por el validador (token/password/cabecera Authorization/query string) dentro de los logs') }
}

Invoke-Prueba 'L09' 'Niveles de log acordes al resultado (Information/Warning/Error)' 3 {
    param($f)
    if ($comp.Count -eq 0) { $f.Add('sin eventos de finalización que evaluar') }
    elseif ($script:NivelFallos.Count -gt 0) {
        $txt = ($script:NivelFallos -join '; ')
        if ($txt.Length -gt 400) { $txt = $txt.Substring(0, 400) }
        $f.Add("$($script:NivelFallos.Count) nivel(es) incorrecto(s): 2xx=Information, 4xx=Warning, 5xx=Error. $txt")
    }
}

# ============================================================================
#  Resumen
# ============================================================================
$total = [double](($script:Resultados | Measure-Object -Property Puntos -Sum).Sum)
$obt = [double](($script:Resultados | Where-Object { $_.Ok } | Measure-Object -Property Puntos -Sum).Sum)
$ci = [System.Globalization.CultureInfo]::InvariantCulture
$pct = if ($total -gt 0) { [math]::Round($obt * 100 / $total, 1) } else { 0 }
$nota = if ($total -gt 0) { [math]::Round($obt * 10 / $total, 2) } else { 0 }

Write-Host ''
Write-Host '============================================================'
Write-Host (' Puntos:        {0} / {1}' -f $obt, $total)
Write-Host (' Cumplimiento:  {0} %' -f $pct.ToString('0.0', $ci))
Write-Host (' NOTA ORIENTATIVA: {0} / 10' -f $nota.ToString('0.00', $ci)) -ForegroundColor Cyan
Write-Host '============================================================'
Write-Host ' La nota del validador es orientativa. La calificación final'
Write-Host ' incluye revisión de código, pruebas, informe y defensa técnica.'

try {
    [pscustomobject]@{
        labRunId = $script:RunId
        baseUrl  = $script:Base
        fecha    = (Get-Date).ToUniversalTime().ToString('o')
        puntos   = $obt
        maximo   = $total
        nota     = $nota
        pruebas  = @($script:Resultados | ForEach-Object { [pscustomobject]@{ id = $_.Id; nombre = $_.Nombre; puntos = $_.Puntos; aprobado = $_.Ok; detalle = $_.Detalle } })
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $Reporte -Encoding utf8
    Write-Host " Reporte JSON: $Reporte"
}
catch { }
exit 0
