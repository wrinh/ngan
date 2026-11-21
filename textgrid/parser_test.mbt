// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Blackbox tests for Praat .TextGrid parsing, serialization, and queries.

///|
fn expect_parse_error(
  src : String,
  label : String,
) -> @types.TextGridError raise {
  try @textgrid.parse_textgrid(src) catch {
    err => err
  } noraise {
    _ => fail("expected parse error for \{label}")
  }
}

///|
test "parse long TextGrid with IntervalTier and TextTier" {
  let src =
    #|File type = "ooTextFile"
    #|Object class = "TextGrid"
    #|
    #|xmin = 0 
    #|xmax = 1.5 
    #|tiers? <exists> 
    #|size = 2 
    #|item []: 
    #|    item [1]:
    #|        class = "IntervalTier" 
    #|        name = "phones" 
    #|        xmin = 0 
    #|        xmax = 1.5 
    #|        intervals: size = 3 
    #|        intervals [1]:
    #|            xmin = 0 
    #|            xmax = 0.25 
    #|            text = "" 
    #|        intervals [2]:
    #|            xmin = 0.25 
    #|            xmax = 1.0 
    #|            text = "ŋan" 
    #|        intervals [3]:
    #|            xmin = 1.0 
    #|            xmax = 1.5 
    #|            text = "tɕʰi⁵⁵ 啊" 
    #|    item [2]:
    #|        class = "TextTier" 
    #|        name = "events" 
    #|        xmin = 0 
    #|        xmax = 1.5 
    #|        points: size = 2 
    #|        points [1]:
    #|            number = 0.5 
    #|            mark = "say ""hi""" 
    #|        points [2]:
    #|            time = 1.25 
    #|            mark = """" 
  let tg = @textgrid.parse_textgrid(src)
  assert_eq(tg.xmin, 0.0)
  assert_eq(tg.xmax, 1.5)
  assert_eq(tg.tiers.length(), 2)
  assert_eq(tg.tiers[0].name(), "phones")
  assert_eq(tg.tiers[0].xmin(), 0.0)
  assert_eq(tg.tiers[0].xmax(), 1.5)
  assert_eq(tg.tiers[1].name(), "events")
  guard tg.interval_tier("phones") is Some(phones) else {
    fail("missing phones IntervalTier")
  }
  assert_eq(phones.intervals.length(), 3)
  assert_eq(phones.intervals[0].text, "")
  assert_eq(phones.intervals[1].text, "ŋan")
  assert_eq(phones.intervals[2].text, "tɕʰi⁵⁵ 啊")
  assert_eq(phones.intervals[1].duration(), 0.75)
  assert_eq(phones.intervals[1].midpoint(), 0.625)
  // interval_at boundaries: left-closed, right-closed on last interval
  assert_eq(phones.interval_at(0.0).map(iv => iv.text), Some(""))
  assert_eq(phones.interval_at(0.25).map(iv => iv.text), Some("ŋan"))
  assert_eq(
    phones.interval_at(1.5).map(iv => iv.text),
    Some("tɕʰi⁵⁵ 啊"),
  )
  assert_true(phones.interval_at(-0.01) is None)
  assert_true(phones.interval_at(1.51) is None)

  guard tg.point_tier("events") is Some(events) else {
    fail("missing events PointTier")
  }
  assert_eq(events.points.length(), 2)
  assert_eq(events.points[0], { time: 0.5, mark: "say \"hi\"", })
  assert_eq(events.points[1], { time: 1.25, mark: "\"", })
  assert_true(tg.tier_by_name("phones") is Some(Intervals(_)))
  assert_true(tg.tier_by_name("events") is Some(Points(_)))
  assert_true(tg.tier_by_name("missing") is None)
  assert_true(tg.interval_tier("events") is None)
  assert_true(tg.point_tier("phones") is None)
  assert_eq(tg.interval_tiers().length(), 1)
}

///|
test "parse short and chronological TextGrid formats and round-trip" {
  let short_src =
    #|"ooTextFile"
    #|"TextGrid"
    #|0
    #|1.2
    #|<exists>
    #|2
    #|"IntervalTier"
    #|"words"
    #|0
    #|1.2
    #|2
    #|0
    #|0.6
    #|"hello ""world"""
    #|0.6
    #|1.2
    #|"bye"
    #|"TextTier"
    #|"tones"
    #|0
    #|1.2
    #|1
    #|0.3
    #|"H*"
  let tg_short = @textgrid.parse_textgrid(short_src)

  let chrono_src =
    #|"ooTextFile"
    #|"TextGrid"
    #|0.0 1.2 ! global domain
    #|2 ! tier count
    #|"IntervalTier" "words" 0 1.2
    #|"TextTier" "tones" 0 1.2
    #|! interleaved chronological records
    #|1 0 0.6 "hello ""world"""
    #|2 0.3 "H*"
    #|1 0.6 1.2 "bye"
  let tg_chrono = @textgrid.parse_textgrid(chrono_src)
  assert_eq(tg_short, tg_chrono)

  // Round-trip through both long and short serializers
  let long_out = @textgrid.to_textgrid_string(tg_short, short=false)
  let short_out = @textgrid.to_textgrid_string(tg_short, short=true)
  assert_eq(@textgrid.parse_textgrid(long_out), tg_short)
  assert_eq(@textgrid.parse_textgrid(short_out), tg_short)
}

///|
test "parse BOM, CRLF/CR endings, multiline quoted strings, absent and empty tiers" {
  let bom_crlf = "\u{FEFF}\"ooTextFile\"\r\n\"TextGrid\"\r\n.25\r+1.5e0\r<exists>\r\n1\r\n\"IntervalTier\"\r\n\"seg\"\r\n0.25\r\n1.5\r\n1\r\n0.25\r\n1.5\r\n\"line1\r\nline2\"\r\n"
  let tg = @textgrid.parse_textgrid(bom_crlf)
  assert_eq(tg.xmin, 0.25)
  assert_eq(tg.xmax, 1.5)
  guard tg.interval_tier("seg") is Some(seg) else { fail("missing seg tier") }
  assert_eq(seg.intervals[0].text, "line1\nline2")

  let absent_src =
    #|File type = "ooTextFile"
    #|Object class = "TextGrid"
    #|xmin = 0
    #|xmax = 2.0
    #|tiers? <absent>
  let tg_absent = @textgrid.parse_textgrid(absent_src)
  assert_eq(tg_absent.tiers.length(), 0)
  assert_eq(tg_absent.xmin, 0.0)
  assert_eq(tg_absent.xmax, 2.0)

  let zero_tiers_src =
    #|File type = "ooTextFile"
    #|Object class = "TextGrid"
    #|xmin = 0
    #|xmax = 2.0
    #|tiers? <exists>
    #|size = 0
    #|item []:
  assert_eq(@textgrid.parse_textgrid(zero_tiers_src), tg_absent)
}

///|
test "parse_textgrid rejects malformed inputs with line info" {
  ignore(expect_parse_error("", "empty"))
  ignore(
    expect_parse_error(
      "File type = \"other\"\nObject class = \"TextGrid\"\n0\n1\n<absent>", "wrong file type",
    ),
  )
  ignore(
    expect_parse_error(
      "File type = \"ooTextFile\"\nObject class = \"Sound\"\n0\n1\n<absent>", "wrong object class",
    ),
  )
  ignore(
    expect_parse_error(
      "\"ooTextFile\"\n\"TextGrid\"\n0\n1\n<exists>\n1\n\"IntervalTier\"\n\"unterminated\n0\n1\n0",
      "unterminated string",
    ),
  )
  ignore(
    expect_parse_error(
      "\"ooTextFile\"\n\"TextGrid\"\n0\n1\n<exists\n0", "unterminated flag",
    ),
  )
  ignore(
    expect_parse_error(
      "\"ooTextFile\"\n\"TextGrid\"\n0\n1\n<exists>\nitem [1\n0", "unterminated bracket",
    ),
  )
  ignore(
    expect_parse_error(
      "\"ooTextFile\"\n\"TextGrid\"\n2\n1\n<absent>", "xmin > xmax",
    ),
  )
  ignore(
    expect_parse_error(
      "\"ooTextFile\"\n\"TextGrid\"\n0\n1\n<exists>\n1\n\"UnknownTier\"\n\"x\"\n0\n1\n0",
      "unknown tier class",
    ),
  )
  ignore(
    expect_parse_error(
      "\"ooTextFile\"\n\"TextGrid\"\n0\n1\n<exists>\n-1", "negative size",
    ),
  )
  ignore(
    expect_parse_error(
      "\"ooTextFile\"\n\"TextGrid\"\n12abc\n1\n<absent>", "numeric suffix",
    ),
  )
  ignore(
    expect_parse_error(
      "\"ooTextFile\"\n\"TextGrid\"\n1.2.3\n2\n<absent>", "double dot",
    ),
  )
  ignore(
    expect_parse_error(
      "\"ooTextFile\"\n\"TextGrid\"\n1e\n2\n<absent>", "broken exponent",
    ),
  )
  ignore(
    expect_parse_error(
      "\"ooTextFile\"\n\"TextGrid\"\n0\n1\n1\n\"IntervalTier\" \"a\" 0 1\n2 0 1 \"x\"",
      "chronological tier index out of bounds",
    ),
  )
  ignore(
    expect_parse_error(
      "\"ooTextFile\"\n\"TextGrid\"\n0\n1\n<absent>\n\"trailing\"", "trailing token",
    ),
  )
}
