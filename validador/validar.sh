#!/usr/bin/env bash
# =============================================================================
#  validar.sh - Validador del laboratorio "Operación Rescate"
#
#  Uso:      bash ./validar.sh [BASE_URL] [LOG_DIR]
#  Ejemplo:  bash ./validar.sh http://localhost:5000 ./logs
#  Requiere: bash, curl y jq.   (Linux, macOS o Git Bash con jq instalado)
#
#  Qué hace:
#    1. Ejecuta peticiones reales contra la API (con identificadores únicos
#       generados en CADA ejecución del validador).
#    2. Verifica respuestas HTTP, cabecera X-Correlation-ID y errores seguros.
#    3. Lee los archivos de la carpeta de logs y comprueba que lo registrado
#       corresponde EXACTAMENTE a las peticiones que este script acaba de hacer.
#    4. Calcula el puntaje (sobre 100) y la nota (sobre 10).
#
#  Variables opcionales:  ESPERA_LOGS (segundos, por defecto 1.5)
#                         REPORTE     (ruta del JSON de resultados)
# =============================================================================

BASE_URL="${1:-http://localhost:5000}"
LOG_DIR="${2:-./logs}"
ESPERA_LOGS="${ESPERA_LOGS:-1.5}"
REPORTE="${REPORTE:-./reporte-validacion.json}"
BASE_URL="${BASE_URL%/}"

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Falta '$cmd'. Instálalo e inténtalo de nuevo."; exit 2; }
done

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t validar)"
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/res.tsv"
: > "$TMP/enviadas.tsv"

if [[ -t 1 ]]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; NC=$'\033[0m'
else
  G=""; R=""; Y=""; B=""; NC=""
fi

# ----------------------------------------------------------------------------
#  Utilidades
# ----------------------------------------------------------------------------
lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
is_int() { [[ "$1" =~ ^-?[0-9]+$ ]]; }
num_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>=b+0)}'; }
num_gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>b+0)}'; }
num_le() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0<=b+0)}'; }

newguid() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  else printf '%04x%04x-%04x-4%03x-a%03x-%04x%04x%04x' $RANDOM $RANDOM $RANDOM $((RANDOM%4096)) $((RANDOM%4096)) $RANDOM $RANDOM $RANDOM
  fi
}

GUID_RX='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
RUN_ID="run-$(newguid | tr -d '-' | cut -c1-12)"
CANARY="CANARY-$(newguid | tr -d '-')"

# api METHOD RUTA [CUERPO] [CABECERA...]
# Deja el resultado en: STATUS, BODY, RCID (X-Correlation-ID de la respuesta), CTYPE
api() {
  local method="$1" path="$2" body="${3-}"
  shift; shift; [[ $# -gt 0 ]] && shift
  local args=(-s -m 30 -X "$method" -D "$TMP/h" -o "$TMP/b" -w '%{http_code}' -H "X-Lab-Run-Id: $RUN_ID")
  local h
  for h in "$@"; do args+=(-H "$h"); done
  if [[ -n "$body" ]]; then args+=(-H "Content-Type: application/json" --data-binary "$body"); fi
  : > "$TMP/h"; : > "$TMP/b"
  STATUS=$(curl "${args[@]}" "$BASE_URL$path" 2>/dev/null) || STATUS=0
  STATUS=$((10#${STATUS:-0}))
  BODY="$(cat "$TMP/b" 2>/dev/null)"
  RCID="$(grep -i '^x-correlation-id:' "$TMP/h" | head -1 | cut -d: -f2- | tr -d ' \r\n')"
  CTYPE="$(grep -i '^content-type:' "$TMP/h" | head -1 | cut -d: -f2- | tr -d '\r\n' | cut -d';' -f1 | tr -d ' ')"
  printf '%s\t%s\t%s\t%s\n' "$method" "${path%%\?*}" "$STATUS" "$RCID" >> "$TMP/enviadas.tsv"
}

get_stock() { api GET "/api/inventario/$1"; printf '%s' "$BODY" | jq -r '.stock // empty' 2>/dev/null; }

# Devuelve un texto de error si el cuerpo expone información técnica
cuerpo_inseguro() {
  local m
  m="$(printf '%s' "$1" | grep -Eo 'StackTrace|stackTrace|Fallo simulado| at [A-Za-z_][A-Za-z0-9_.<>]*\(|\.cs[^A-Za-z]|System\.|Microsoft\.|[A-Za-z]:\\|/home/|/usr/|/app/|/src/|Exception' | head -1)"
  [[ -n "$m" ]] && echo "el cuerpo expone información técnica (coincide con '$m')"
}

# Valida una respuesta de error: estado, JSON (problem details), correlationId y seguridad
problem_error() {
  local exp="$1" st cid
  if [[ "$STATUS" -ne "$exp" ]]; then echo "estado $STATUS (esperado $exp)"; return; fi
  if [[ "$CTYPE" != *json* ]]; then echo "Content-Type '$CTYPE' no es JSON (se espera application/problem+json)"; return; fi
  if ! printf '%s' "$BODY" | jq -e 'type=="object"' >/dev/null 2>&1; then echo "el cuerpo no es un objeto JSON válido"; return; fi
  st="$(printf '%s' "$BODY" | jq -r '.status // empty')"
  cid="$(printf '%s' "$BODY" | jq -r '.correlationId // empty')"
  if [[ "$st" != "$exp" ]]; then echo "el campo 'status' del cuerpo es '$st'"; return; fi
  if [[ -z "$cid" || "$(lc "$cid")" != "$(lc "$RCID")" ]]; then
    echo "'correlationId' del cuerpo ('$cid') no coincide con la cabecera X-Correlation-ID ('$RCID')"; return
  fi
  cuerpo_inseguro "$BODY"
}

# Registro de resultados
ok=1; det=""
begin() { ok=1; det=""; }
fail()  { ok=0; det="${det}${1}; "; }
end_test() { # id nombre puntos
  local d="${det%; }"
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$ok" "$d" >> "$TMP/res.tsv"
  if [[ "$ok" == "1" ]]; then
    printf '  %s[ OK ]%s %-4s %s (%s pts)\n' "$G" "$NC" "$1" "$2" "$3"
  else
    printf '  %s[FAIL]%s %-4s %s (0/%s pts)\n         -> %s\n' "$R" "$NC" "$1" "$2" "$3" "$d"
  fi
}
seccion() { printf '\n%s%s%s\n' "$B" "$1" "$NC"; }

echo "============================================================"
echo " Validador - Operación Rescate"
echo " API:      $BASE_URL"
echo " Logs:     $LOG_DIR"
echo " LabRunId: $RUN_ID"
echo "============================================================"

api GET /api/inventario
if [[ "$STATUS" -eq 0 ]]; then
  echo "${R}No se pudo conectar con $BASE_URL. ¿La API está en ejecución y el puerto es correcto?${NC}"
  exit 2
fi

BIZ_CIDS=""   # correlation ids de errores de negocio (400/404/409): no deben registrarse como Error
EXC_CID=""    # correlation id de la excepción de laboratorio

# ============================================================================
seccion "1) Comportamiento de la API"
# ============================================================================

begin
api GET /api/inventario/LAP-001
if [[ "$STATUS" -ne 200 ]]; then fail "estado $STATUS (esperado 200)"; else
  [[ "$(printf '%s' "$BODY" | jq -r '.sku // empty' 2>/dev/null | tr a-z A-Z)" == "LAP-001" ]] || fail "el cuerpo no contiene sku=LAP-001"
  printf '%s' "$BODY" | jq -e '.stock|type=="number"' >/dev/null 2>&1 || fail "el cuerpo no contiene 'stock' numérico"
fi
end_test T01 "Consultar inventario existente (200)" 5

begin
api GET /api/inventario/NOEXISTE-999
BIZ_CIDS="$BIZ_CIDS $RCID"
e="$(problem_error 404)"; [[ -z "$e" ]] || fail "$e"
end_test T02 "Consultar inventario inexistente (404 seguro y consistente)" 5

begin
S0="$(get_stock LAP-001)"
PED="$(printf '{"clienteId":"CLI-001","password":"%s","items":[{"sku":"LAP-001","cantidad":1}]}' "$CANARY")"
api POST /api/pedidos "$PED" "Authorization: Bearer $CANARY"
if [[ "$STATUS" -ne 201 ]]; then fail "estado $STATUS (esperado 201)"; else
  [[ -n "$(printf '%s' "$BODY" | jq -r '.id // empty' 2>/dev/null)" ]] || fail "la respuesta no incluye 'id' del pedido"
  S1="$(get_stock LAP-001)"
  if is_int "$S0" && is_int "$S1"; then
    [[ "$S1" -eq $((S0-1)) ]] || fail "el stock debía pasar de $S0 a $((S0-1)) y quedó en $S1"
  else fail "no se pudo leer el stock antes/después del pedido"; fi
fi
end_test T03 "Crear pedido válido (201 y descuento de stock)" 6

begin
api POST /api/pedidos '{"clienteId":"CLI-001","items":[{"sku":"LAP-001","cantidad":0}]}'
BIZ_CIDS="$BIZ_CIDS $RCID"
e="$(problem_error 400)"; [[ -z "$e" ]] || fail "$e"
end_test T04 "Pedido con cantidad cero (400)" 5

begin
S0="$(get_stock LAP-001)"
api POST /api/pedidos '{"clienteId":"CLI-001","items":[{"sku":"LAP-001","cantidad":-5}]}'
BIZ_CIDS="$BIZ_CIDS $RCID"
e="$(problem_error 400)"; [[ -z "$e" ]] || fail "$e"
S1="$(get_stock LAP-001)"
if is_int "$S0" && is_int "$S1"; then [[ "$S1" -eq "$S0" ]] || fail "una cantidad negativa modificó el stock ($S0 -> $S1)"; fi
end_test T05 "Pedido con cantidad negativa (400, sin alterar stock)" 3

begin
SS="$(get_stock SSD-005)"
if is_int "$SS"; then
  S_ANTES="$SS"
  api POST /api/pedidos "$(printf '{"clienteId":"CLI-001","items":[{"sku":"SSD-005","cantidad":%d}]}' $((SS+1)))"
  BIZ_CIDS="$BIZ_CIDS $RCID"
  e="$(problem_error 409)"; [[ -z "$e" ]] || fail "$e"
  SS2="$(get_stock SSD-005)"
  [[ "$SS2" == "$S_ANTES" ]] || fail "el pedido rechazado alteró el stock de SSD-005 ($S_ANTES -> $SS2)"
else fail "no se pudo leer el stock de SSD-005"; fi
end_test T06 "Pedido superior al inventario (409, sin alterar stock)" 6

begin
api POST /api/pedidos '{"clienteId":"CLI-001","items":['
BIZ_CIDS="$BIZ_CIDS $RCID"
e="$(problem_error 400)"; [[ -z "$e" ]] || fail "JSON malformado: $e"
api POST /api/pedidos '{"clienteId":"CLI-001","items":[]}'
BIZ_CIDS="$BIZ_CIDS $RCID"
e="$(problem_error 400)"; [[ -z "$e" ]] || fail "items vacío: $e"
end_test T07 "JSON malformado o pedido sin items (400)" 5

begin
api POST /api/pedidos '{"clienteId":"CLI-001","items":[{"sku":"NOEXISTE-000","cantidad":1}]}'
BIZ_CIDS="$BIZ_CIDS $RCID"
e="$(problem_error 404)"; [[ -z "$e" ]] || fail "$e"
end_test T08 "Pedido con SKU inexistente (404)" 3

begin
api GET /api/lab/excepcion
EXC_CID="$RCID"
e="$(problem_error 500)"; [[ -z "$e" ]] || fail "$e"
end_test T09 "Excepción de laboratorio (500 seguro, sin detalles técnicos)" 6

# ============================================================================
seccion "2) Identificador de correlación"
# ============================================================================

begin
G1="$(newguid)"
api GET /api/inventario/MOU-002 "" "X-Correlation-ID: $G1"
[[ "$(lc "$RCID")" == "$(lc "$G1")" ]] || fail "se envió $G1 y la respuesta devolvió '${RCID}'"
end_test C01 "Acepta y devuelve un X-Correlation-ID válido" 4

begin
MAL=("abc-$(newguid)-zzz" "$(printf 'x%.0s' $(seq 1 300))" "no es un guid; DROP TABLE")
for m in "${MAL[@]}"; do
  api GET /api/inventario/MOU-002 "" "X-Correlation-ID: $m"
  if [[ ! "$RCID" =~ $GUID_RX ]]; then fail "para '${m:0:40}' no se generó un GUID válido (respuesta: '${RCID:0:60}')"
  elif [[ "$(lc "$RCID")" == "$(lc "$m")" ]]; then fail "se aceptó un identificador malformado: '${m:0:40}'"; fi
done
end_test C02 "Reemplaza identificadores malformados por un GUID nuevo" 4

begin
api GET /api/inventario/MOU-002; A1="$RCID"
api GET /api/inventario/MOU-002; A2="$RCID"
[[ "$A1" =~ $GUID_RX ]] || fail "sin cabecera entrante no se generó un GUID válido ('$A1')"
[[ "$A2" =~ $GUID_RX ]] || fail "segunda petición sin identificador no devolvió un GUID válido ('$A2')"
[[ -n "$A1" && "$(lc "$A1")" != "$(lc "$A2")" ]] || fail "dos peticiones distintas recibieron el mismo identificador"
end_test C03 "Genera un identificador cuando no llega ninguno" 3

begin
NCON=20
for i in $(seq 1 $NCON); do
  g="$(newguid)"; printf '%s' "$g" > "$TMP/c$i.id"
  if (( i % 2 == 0 )); then p="/api/inventario/LAP-001"; else p="/api/lab/lento?ms=150"; fi
  ( curl -s -m 30 -o "$TMP/c$i.b" -D "$TMP/c$i.h" -w '%{http_code}' -H "X-Lab-Run-Id: $RUN_ID" -H "X-Correlation-ID: $g" "$BASE_URL$p" > "$TMP/c$i.s" 2>/dev/null ) &
done
wait
BADC=0
for i in $(seq 1 $NCON); do
  sent="$(cat "$TMP/c$i.id")"
  got="$(grep -i '^x-correlation-id:' "$TMP/c$i.h" 2>/dev/null | head -1 | cut -d: -f2- | tr -d ' \r\n')"
  st="$(cat "$TMP/c$i.s" 2>/dev/null)"; st=$((10#${st:-0}))
  if (( i % 2 == 0 )); then p="/api/inventario/LAP-001"; else p="/api/lab/lento"; fi
  printf 'GET\t%s\t%s\t%s\n' "$p" "$st" "$got" >> "$TMP/enviadas.tsv"
  [[ "$(lc "$got")" == "$(lc "$sent")" && "$st" -eq 200 ]] || BADC=$((BADC+1))
done
[[ "$BADC" -eq 0 ]] || fail "$BADC de $NCON peticiones simultáneas no conservaron su propio identificador o no devolvieron 200"
end_test C04 "Peticiones simultáneas conservan su propio identificador" 4

# Peticiones para medir tiempos
api GET "/api/lab/lento?ms=300"; LENTO1="$RCID"
api GET "/api/lab/lento?ms=800"; LENTO2="$RCID"
api GET "/api/inventario/MOU-002?token=$CANARY"; RAPIDA="$RCID"

# ============================================================================
seccion "3) Logs estructurados"
# ============================================================================
sleep "$ESPERA_LOGS"

: > "$TMP/logs.jsonl"
NFILES=0
if [[ -d "$LOG_DIR" ]]; then
  while IFS= read -r f; do
    NFILES=$((NFILES+1))
    jq -cR 'select(length>0) | (try (fromjson | if type=="object" then . else {"__invalid":1} end) catch {"__invalid":1})' "$f" >> "$TMP/logs.jsonl" 2>/dev/null
  done < <(find "$LOG_DIR" -type f)
fi
TOTAL_LINES="$(wc -l < "$TMP/logs.jsonl" | tr -d ' ')"
INVALID="$(jq -c 'select(.__invalid)' "$TMP/logs.jsonl" | wc -l | tr -d ' ')"

IDS="$(cut -f4 "$TMP/enviadas.tsv" | grep -v '^$' | jq -R 'ascii_downcase' | jq -sc .)"
[[ -n "$IDS" ]] || IDS="[]"
jq -c --argjson ids "$IDS" 'select(.__invalid|not) | select((.CorrelationId|type)=="string") | select(.CorrelationId|ascii_downcase as $c | any($ids[]; .==$c))' "$TMP/logs.jsonl" > "$TMP/ev_sent.jsonl"
jq -c 'select(.ElapsedMs != null)' "$TMP/ev_sent.jsonl" > "$TMP/comp.jsonl"
NCOMP="$(wc -l < "$TMP/comp.jsonl" | tr -d ' ')"
NSENT="$(wc -l < "$TMP/ev_sent.jsonl" | tr -d ' ')"

# eventos (de un archivo jsonl) de un correlation id
cevents() { jq -c --arg c "$(lc "$1")" 'select((.CorrelationId|ascii_downcase)==$c)' "$2"; }

begin
[[ "$NFILES" -gt 0 ]] || fail "no existen archivos dentro de '$LOG_DIR'"
[[ "$TOTAL_LINES" -gt 0 ]] || fail "los archivos de log están vacíos"
end_test L01 "Existen archivos de log con contenido" 3

begin
if [[ "$TOTAL_LINES" -eq 0 ]]; then fail "no hay líneas que validar"
elif [[ "$INVALID" -gt 0 ]]; then fail "$INVALID línea(s) no son un objeto JSON válido (se exige un evento JSON por línea)"; fi
end_test L02 "Formato JSON Lines (un JSON válido por línea)" 3

begin
if [[ "$NCOMP" -eq 0 ]]; then fail "no se encontró ningún evento de finalización (evento con ElapsedMs) de las peticiones ejecutadas"
else
  BAD="$(jq -c '. as $e | select(
      (($e.Timestamp|type)!="string") or ((($e.Timestamp|tostring)|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?Z$"))|not)
   or (($e.Level|type)!="string") or ((["Verbose","Debug","Information","Warning","Error","Fatal"]|index($e.Level))==null)
   or (($e.MessageTemplate|type)!="string") or (($e.MessageTemplate|length)==0)
   or (($e.RequestMethod|type)!="string") or (($e.RequestPath|type)!="string")
   or (($e.StatusCode|type)!="number") or (($e.ElapsedMs|type)!="number") or ($e.ElapsedMs<0)
   or (($e.CorrelationId|type)!="string") or (($e.LabRunId|type)!="string"))' "$TMP/comp.jsonl")"
  if [[ -n "$BAD" ]]; then
    NB="$(printf '%s\n' "$BAD" | wc -l | tr -d ' ')"
    fail "$NB evento(s) de finalización con propiedades ausentes o con tipo/formato incorrecto (Timestamp UTC con 'Z', Level válido, StatusCode y ElapsedMs numéricos...). Ejemplo: $(printf '%s' "$BAD" | head -1 | cut -c1-260)"
  fi
fi
end_test L03 "Propiedades obligatorias en el evento de finalización" 5

begin
FAILS=""; NF=0; LFAILS=""; NLF=0
while IFS=$'\t' read -r m p s c; do
  if [[ -z "$c" ]]; then NF=$((NF+1)); FAILS="$FAILS [$m $p] la respuesta no trae X-Correlation-ID;"; continue; fi
  evs="$(cevents "$c" "$TMP/comp.jsonl")"
  n="$(printf '%s' "$evs" | grep -c .)"
  if [[ "$n" -eq 0 ]]; then NF=$((NF+1)); FAILS="$FAILS [$m $p $s] sin evento de finalización para el id $c;"
  elif [[ "$n" -gt 1 ]]; then NF=$((NF+1)); FAILS="$FAILS [$m $p $s] $n eventos de finalización para el mismo id (duplicado);"
  else
    em="$(printf '%s' "$evs" | jq -r '.RequestMethod|ascii_downcase')"
    ep="$(printf '%s' "$evs" | jq -r '.RequestPath|ascii_downcase')"
    es="$(printf '%s' "$evs" | jq -r '.StatusCode')"
    el="$(printf '%s' "$evs" | jq -r '.Level')"
    if [[ "$em" != "$(lc "$m")" || "$ep" != "$(lc "$p")" || "$es" != "$s" ]]; then
      NF=$((NF+1)); FAILS="$FAILS [$m $p $s] el log dice '$em $ep $es';"
    fi
    case "$s" in
      2??|3??) exp_l="Information" ;;
      4??)     exp_l="Warning" ;;
      5??)     exp_l="Error" ;;
      *)       exp_l="" ;;
    esac
    if [[ -n "$exp_l" && "$el" != "$exp_l" ]]; then NLF=$((NLF+1)); LFAILS="$LFAILS [$m $p $s] nivel '$el' (esperado $exp_l);"; fi
  fi
done < "$TMP/enviadas.tsv"
[[ "$NF" -eq 0 ]] || fail "$NF petición(es) sin un único evento correcto. ${FAILS:0:600}"
end_test L04 "Cada petición ejecutada tiene exactamente un evento de finalización correcto" 8

begin
e1="$(cevents "$LENTO1" "$TMP/comp.jsonl" | head -1 | jq -r '.ElapsedMs // empty' 2>/dev/null)"
e2="$(cevents "$LENTO2" "$TMP/comp.jsonl" | head -1 | jq -r '.ElapsedMs // empty' 2>/dev/null)"
ef="$(cevents "$RAPIDA" "$TMP/comp.jsonl" | head -1 | jq -r '.ElapsedMs // empty' 2>/dev/null)"
if [[ -z "$e1" || -z "$e2" || -z "$ef" ]]; then fail "faltan los eventos de las peticiones de medición de tiempo"
else
  num_ge "$e1" 250 && num_le "$e1" 10000 || fail "petición de 300 ms registró ElapsedMs=$e1 (se esperaba entre 250 y 10000)"
  num_ge "$e2" 700 && num_le "$e2" 15000 || fail "petición de 800 ms registró ElapsedMs=$e2 (se esperaba >= 700)"
  num_gt "$e2" "$e1" || fail "ElapsedMs no refleja la duración real ($e2 no es mayor que $e1)"
  num_gt "$e1" "$ef" || fail "la petición rápida ($ef ms) no es más corta que la lenta ($e1 ms)"
fi
end_test L05 "ElapsedMs refleja el tiempo real de procesamiento" 5

begin
if [[ "$NSENT" -eq 0 ]]; then fail "no hay eventos asociados a las peticiones ejecutadas"
else
  NR="$(jq -c --arg r "$RUN_ID" 'select(.LabRunId != $r)' "$TMP/ev_sent.jsonl" | wc -l | tr -d ' ')"
  [[ "$NR" -eq 0 ]] || fail "$NR evento(s) de peticiones ejecutadas no incluyen LabRunId=$RUN_ID (se envía en la cabecera X-Lab-Run-Id)"
fi
end_test L06 "LabRunId propagado a todos los eventos de cada petición" 4

begin
if [[ -z "$EXC_CID" ]]; then fail "la excepción de laboratorio no devolvió X-Correlation-ID"
else
  cevents "$EXC_CID" "$TMP/ev_sent.jsonl" > "$TMP/exc.jsonl"
  NEXC="$(jq -c 'select((.Exception|type)=="string" and (.Exception|length)>0)' "$TMP/exc.jsonl" | wc -l | tr -d ' ')"
  if [[ "$NEXC" -eq 0 ]]; then fail "no hay ningún evento con la propiedad 'Exception' para la excepción de laboratorio"
  elif [[ "$NEXC" -gt 1 ]]; then fail "la misma excepción se registró $NEXC veces con detalle de Exception (duplicada)"
  else
    jq -e 'select((.Exception|type)=="string") | .Exception | contains("Fallo simulado")' "$TMP/exc.jsonl" >/dev/null 2>&1 || fail "la propiedad Exception no conserva el mensaje/traza real del error"
  fi
  LVL="$(cevents "$EXC_CID" "$TMP/comp.jsonl" | head -1 | jq -r '.Level // empty')"
  [[ "$LVL" == "Error" ]] || fail "el evento de finalización de la excepción tiene nivel '$LVL' (esperado Error)"
fi
NBIZ=0
for c in $BIZ_CIDS; do
  [[ -n "$c" ]] || continue
  cnt="$(cevents "$c" "$TMP/ev_sent.jsonl" | jq -c 'select(.Level=="Error" or .Level=="Fatal")' | wc -l | tr -d ' ')"
  [[ "$cnt" -eq 0 ]] || NBIZ=$((NBIZ+1))
done
[[ "$NBIZ" -eq 0 ]] || fail "$NBIZ error(es) de negocio (400/404/409) se registraron con nivel Error/Fatal como si fueran excepciones internas"
end_test L07 "Excepción registrada una sola vez; errores de negocio no son 'Error'" 6

begin
if [[ "$TOTAL_LINES" -eq 0 ]]; then fail "no hay logs que revisar"
elif grep -rFq -- "$CANARY" "$LOG_DIR" 2>/dev/null; then fail "se encontró información sensible enviada por el validador (token/password/cabecera Authorization/query string) dentro de los logs"
fi
end_test L08 "Los logs no contienen datos sensibles" 4

begin
if [[ "$NCOMP" -eq 0 ]]; then fail "sin eventos de finalización que evaluar"
elif [[ "$NLF" -gt 0 ]]; then fail "$NLF nivel(es) incorrecto(s): 2xx=Information, 4xx=Warning, 5xx=Error. ${LFAILS:0:400}"; fi
end_test L09 "Niveles de log acordes al resultado (Information/Warning/Error)" 3

# ============================================================================
#  Resumen
# ============================================================================
TOTAL="$(awk -F'\t' '{t+=$3} END{print t+0}' "$TMP/res.tsv")"
OBT="$(awk -F'\t' '$4==1{t+=$3} END{print t+0}' "$TMP/res.tsv")"
PCT="$(awk -v o="$OBT" -v t="$TOTAL" 'BEGIN{printf "%.1f", (t>0? o*100/t : 0)}')"
NOTA="$(awk -v o="$OBT" -v t="$TOTAL" 'BEGIN{printf "%.2f", (t>0? o*10/t : 0)}')"

echo
echo "============================================================"
printf ' Puntos:        %s / %s\n' "$OBT" "$TOTAL"
printf ' Cumplimiento:  %s %%\n' "$PCT"
printf ' %sNOTA ORIENTATIVA: %s / 10%s\n' "$B" "$NOTA" "$NC"
echo "============================================================"
echo " La nota del validador es orientativa. La calificación final"
echo " incluye revisión de código, pruebas, informe y defensa técnica."

jq -Rn --arg run "$RUN_ID" --arg url "$BASE_URL" --argjson o "$OBT" --argjson t "$TOTAL" '
  [inputs | split("\t") | {id:.[0], nombre:.[1], puntos:(.[2]|tonumber), aprobado:(.[3]=="1"), detalle:(.[4] // "")}] as $p
  | {labRunId:$run, baseUrl:$url, fecha:(now|todate), puntos:$o, maximo:$t, nota:((($o*1000/$t)|round)/100), pruebas:$p}' "$TMP/res.tsv" > "$REPORTE" 2>/dev/null \
  && echo " Reporte JSON: $REPORTE"
exit 0
