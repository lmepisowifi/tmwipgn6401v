#!/bin/sh
PORT=""
INDEX=""
POWER=""       # "enable" | "disable" | "" — independent of speed
SPEED_VALS=""  # non-empty if --speed was given

# --- Argument Parser ---
if [ "$1" = "status" ]; then
    ACTION="status"
    shift

elif [ -n "$1" ]; then
    case "$1" in
        1) PORT=1; INDEX=0 ;;
        2) PORT=2; INDEX=1 ;;
        3) PORT=3; INDEX=2 ;;
        4) PORT=4; INDEX=3 ;;
        *)
            echo "ERROR=\"Expected port (1|2|3|4) or 'status', got: '$1'\""
            exit 1
            ;;
    esac
    shift

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --enable)
                POWER="enable"   # FIX: separate var, doesn't clobber speed
                shift
                ;;
            --disable)
                POWER="disable"
                shift
                ;;
            --speed)
                shift
                while [ "$#" -gt 0 ] && ! echo "$1" | grep -q "^--"; do
                    SPEED_VALS="$SPEED_VALS $1"
                    shift
                done
                SPEED_VALS="${SPEED_VALS# }"
                ;;
            *)
                echo "ERROR=\"Unknown argument: '$1'\""
                exit 1
                ;;
        esac
    done
else
    echo "ERROR=\"No action specified\""
    exit 1
fi

# --- Guard: at least one thing to do ---
if [ "$ACTION" != "status" ] && [ -z "$POWER" ] && [ -z "$SPEED_VALS" ]; then
    echo "ERROR=\"No action specified for port $PORT\""
    exit 1
fi

# --- Logic: Status ---
if [ "$ACTION" = "status" ]; then
    RAW_PWR=$(diag port get phy-force-power-down port all)
    RESULT=""

    for i in 0 1 2 3; do
        PORT_NUM=$((i + 1))   # FIX: output as PORT1_/PORT2_/PORT3_/PORT4_ to match user-facing port numbers

        # Power state: "phy-force-power-down = Disable" means power-down is OFF → port is UP
        if echo "$RAW_PWR" | grep -Ei "port:$i[[:space:]]+Disable" >/dev/null 2>&1; then
            P_STATE="enabled"
        else
            P_STATE="disabled"
        fi 

        # Auto-negotiation ability — trim and word-split into positional vars
        # Columns: (index) 1000F 100F 100H 10F 10H
        RAW_SPEED=$(diag port get auto-nego port "$i" ability | grep "^$i " | tr -s ' ')

        # FIX: replace 5x busybox cut calls with a single word-split (no external tool needed)
        set -- $RAW_SPEED
        C_1000F=$2  C_100F=$3  C_100H=$4  C_10F=$5  C_10H=$6

        # FIX: "auto" now requires ALL 5 speeds enabled — was only checking 3,
        # making it inconsistent with "--speed auto" which sets all 5
        if [ "$C_1000F" = "En" ] && [ "$C_100F" = "En" ] && [ "$C_100H" = "En" ] \
        && [ "$C_10F"   = "En" ] && [ "$C_10H"  = "En" ]; then
            P_SPEED="auto"
        else
            P_SPEED=""
            [ "$C_1000F" = "En" ] && P_SPEED="${P_SPEED}1000F,"
            [ "$C_100F"  = "En" ] && P_SPEED="${P_SPEED}100F,"
            [ "$C_100H"  = "En" ] && P_SPEED="${P_SPEED}100H,"
            [ "$C_10F"   = "En" ] && P_SPEED="${P_SPEED}10F,"
            [ "$C_10H"   = "En" ] && P_SPEED="${P_SPEED}10H,"
            P_SPEED="${P_SPEED%,}"   # FIX: shell trim instead of sed pipe
        fi

        RESULT="${RESULT}PORT${PORT_NUM}_PWR=\"${P_STATE}\" PORT${PORT_NUM}_SPEED=\"${P_SPEED}\" "
    done

    echo "STATUS=\"SUCCESS\" ${RESULT% }"   # FIX: trim trailing space from RESULT
    exit 0
fi

# Build output incrementally
OUT="STATUS=\"SUCCESS\" PORT=\"$PORT\""

# --- Logic: Speed (runs if --speed was given, regardless of --enable/--disable) ---
if [ -n "$SPEED_VALS" ]; then
    if echo "$SPEED_VALS" | grep -qi "auto"; then
        SPEED_VALS="10h 10f 100h 100f 1000f"
    else
        SPEED_VALS_LC=$(echo "$SPEED_VALS" | tr '[:upper:]' '[:lower:]')

        for TOKEN in $SPEED_VALS_LC; do
            case "$TOKEN" in
                10h|10f|100h|100f|1000f) ;;
                *)
                    echo "ERROR=\"Unknown speed value: '$TOKEN'\""
                    exit 1
                    ;;
            esac
        done

        ORDERED=""
        for SPEED in 10h 10f 100h 100f 1000f; do
            case " $SPEED_VALS_LC " in
                *" $SPEED "*) ORDERED="$ORDERED $SPEED" ;;
            esac
        done
        SPEED_VALS="${ORDERED# }"
    fi

    diag port set auto-nego port "$INDEX" ability $SPEED_VALS >/dev/null 2>&1
    OUT="$OUT SPEED_SET=\"$SPEED_VALS\""
fi

# --- Logic: Power (runs if --enable/--disable was given, regardless of --speed) ---
if [ -n "$POWER" ]; then
    if [ "$POWER" = "enable" ]; then
        MIB_VAL=1; PHY_VAL="disable"
    else
        MIB_VAL=0; PHY_VAL="enable"
    fi

    mib set "SW_PORT_TBL.${INDEX}.Enable" "$MIB_VAL" >/dev/null 2>&1
    diag port set phy-force-power-down port "$INDEX" state "$PHY_VAL" >/dev/null 2>&1
    mib commit >/dev/null 2>&1
    OUT="$OUT POWER=\"$POWER\""
fi

echo "$OUT"