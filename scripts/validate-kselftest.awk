# Validate the TAP stream emitted by Linux kselftest.h.
#
# The successful output is deliberately small and machine-readable:
#   {"plan":N,"pass":N,"skip":N,"fail":N}
# This file uses only POSIX awk features; it is also run by /usr/bin/awk on
# macOS in the source-only fixture test.

BEGIN {
    FS = "[ \t]+"
    bad = 0
    version_seen = 0
    plan_seen = 0
    plan = 0
    next_number = 1
    records_seen = 0
    pass_count = 0
    skip_count = 0
    fail_count = 0
    totals_seen = 0
}

{
    # A CR is a line-ending detail, not part of a TAP token.  No other
    # whitespace or garbage is normalized.
    sub(/\r$/, "")

    # kselftest's Totals line is the terminal integrity marker for this
    # gate.  Nothing nonempty may follow it (including comments).
    if (totals_seen) {
        bad = 1
        next
    }

    if ($0 == "TAP version 13") {
        if (version_seen || plan_seen || records_seen || totals_seen)
            bad = 1
        version_seen = 1
        next
    }

    if ($0 ~ /^TAP version[ \t]/) {
        bad = 1
        next
    }

    if ($0 ~ /^1\.\.[1-9][0-9]*$/) {
        if (!version_seen || plan_seen || totals_seen)
            bad = 1
        else {
            plan_seen = 1
            plan = substr($0, 4) + 0
        }
        next
    }

    if ($0 ~ /^1\.\./) {
        bad = 1
        next
    }

    if ($0 ~ /^# Totals:/) {
        # This is the exact summary format printed by kselftest.h.  A
        # malformed summary is not silently treated as an ordinary comment.
        if (totals_seen || !version_seen || !plan_seen ||
            next_number - 1 != plan ||
            $0 !~ /^# Totals: pass:[0-9]+ fail:[0-9]+ xfail:[0-9]+ xpass:[0-9]+ skip:[0-9]+ error:[0-9]+$/) {
            bad = 1
        } else {
            totals_seen = 1
            split($3, summary, ":")
            summary_pass = summary[2] + 0
            split($4, summary, ":")
            summary_fail = summary[2] + 0
            split($5, summary, ":")
            summary_xfail = summary[2] + 0
            split($6, summary, ":")
            summary_xpass = summary[2] + 0
            split($7, summary, ":")
            summary_skip = summary[2] + 0
            split($8, summary, ":")
            summary_error = summary[2] + 0
        }
        next
    }

    # TAP comments are permitted anywhere.  Bailouts are deliberately not
    # comments and therefore fall through to the garbage rejection below.
    if ($0 ~ /^#/) {
        next
    }

    # kselftest emits "ok N name" (without requiring a hyphen).  A test
    # description is optional, as permitted by TAP, but the number is not.
    if (!version_seen || !plan_seen || totals_seen) {
        bad = 1
        next
    }

    record = $0
    status = ""
    if (record ~ /^ok[ \t]+[1-9][0-9]*([ \t].*)?$/) {
        status = "ok"
        sub(/^ok[ \t]+/, "", record)
    } else if (record ~ /^not[ \t]+ok[ \t]+[1-9][0-9]*([ \t].*)?$/) {
        status = "not ok"
        sub(/^not[ \t]+ok[ \t]+/, "", record)
    } else {
        bad = 1
        next
    }

    split(record, fields, /[ \t]+/)
    number = fields[1] + 0
    if (number != next_number)
        bad = 1
    next_number++
    records_seen++

    remainder = record
    sub(/^[1-9][0-9]*/, "", remainder)
    is_skip = 0
    if (remainder ~ /[ \t]+#[ \t]*SKIP([ \t].*)?$/) {
        is_skip = 1
    } else if (remainder ~ /[ \t]+#/) {
        # TODO/XFAIL/XPASS/error and unknown directives are not accepted by
        # this strict gate.  In particular, TODO must never become a pass.
        bad = 1
    } else if (remainder ~ /(^|[ \t])#[ \t]*(TODO|XFAIL|XPASS|ERROR)([ \t]|$)/) {
        bad = 1
    }

    if (is_skip) {
        if (status != "ok")
            bad = 1
        skip_count++
    } else if (status == "ok") {
        pass_count++
    } else {
        fail_count++
    }
}

END {
    if (!version_seen || !plan_seen || next_number - 1 != plan ||
        !totals_seen || pass_count == 0 || fail_count != 0)
        bad = 1

    if (totals_seen &&
        (summary_pass != pass_count || summary_fail != fail_count ||
         summary_xfail != 0 || summary_xpass != 0 ||
         summary_skip != skip_count || summary_error != 0))
        bad = 1

    if (bad)
        exit 1

    printf "{\"plan\":%d,\"pass\":%d,\"skip\":%d,\"fail\":%d}\n", \
        plan, pass_count, skip_count, fail_count
}
