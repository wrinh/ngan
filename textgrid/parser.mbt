// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Praat .TextGrid parser and serializer supporting Long, Short, and
// Chronological ooTextFile TextGrid formats.

///|
priv enum TokenKind {
  Str(String)
  Flag(String)
  Num(String)
}

///|
priv struct Token {
  kind : TokenKind
  line : Int32
}

///|
fn is_ascii_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn is_ascii_alpha(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

///|
fn is_ident_start(c : Char) -> Bool {
  is_ascii_alpha(c) || c == '_'
}

///|
fn is_ident_cont(c : Char) -> Bool {
  is_ascii_alpha(c) ||
  is_ascii_digit(c) ||
  c == '_' ||
  c == '?' ||
  c == ':' ||
  c == '-'
}

///|
fn starts_number(chars : Array[Char], i : Int32) -> Bool {
  let n = chars.length()
  let c = chars[i]
  if is_ascii_digit(c) {
    return true
  }
  if c == '.' {
    return i + 1 < n && is_ascii_digit(chars[i + 1])
  }
  if c == '+' || c == '-' {
    if i + 1 >= n {
      return false
    }
    let next = chars[i + 1]
    if is_ascii_digit(next) {
      return true
    }
    return next == '.' && i + 2 < n && is_ascii_digit(chars[i + 2])
  }
  false
}

///|
fn tokenize(input : String) -> Array[Token] raise @types.TextGridError {
  let chars = input.to_array()
  let n = chars.length()
  let tokens : Array[Token] = []
  let mut i = if n > 0 && chars[0] == '\u{FEFF}' { 1 } else { 0 }
  let mut line : Int32 = 1
  while i < n {
    let c = chars[i]
    if c == '\r' {
      i += if i + 1 < n && chars[i + 1] == '\n' { 2 } else { 1 }
      line += 1
      continue
    }
    if c == '\n' {
      i += 1
      line += 1
      continue
    }
    if c == ' ' || c == '\t' || c == '\u{FEFF}' {
      i += 1
      continue
    }
    if c == '!' {
      while i < n && chars[i] != '\r' && chars[i] != '\n' {
        i += 1
      }
      continue
    }
    if c == '=' || c == ':' || c == '?' {
      i += 1
      continue
    }
    if c == '[' {
      let start_line = line
      i += 1
      while i < n && chars[i] != ']' {
        if chars[i] == '\r' || chars[i] == '\n' {
          raise @types.TextGridError::InvalidFormat(
            line=start_line,
            message="unterminated bracketed index",
          )
        }
        i += 1
      }
      if i >= n {
        raise @types.TextGridError::InvalidFormat(
          line=start_line,
          message="unterminated bracketed index",
        )
      }
      i += 1
      continue
    }
    if c == '"' {
      let start_line = line
      i += 1
      let sb = StringBuilder()
      let mut closed = false
      while i < n {
        let ch = chars[i]
        if ch == '"' {
          if i + 1 < n && chars[i + 1] == '"' {
            sb.write_char('"')
            i += 2
          } else {
            i += 1
            closed = true
            break
          }
        } else if ch == '\r' {
          i += if i + 1 < n && chars[i + 1] == '\n' { 2 } else { 1 }
          line += 1
          sb.write_char('\n')
        } else if ch == '\n' {
          i += 1
          line += 1
          sb.write_char('\n')
        } else {
          sb.write_char(ch)
          i += 1
        }
      }
      if !closed {
        raise @types.TextGridError::InvalidFormat(
          line=start_line,
          message="unterminated string literal",
        )
      }
      tokens.push({ kind: Str(sb.to_string()), line: start_line, })
      continue
    }
    if c == '<' {
      let start_line = line
      i += 1
      let sb = StringBuilder()
      let mut closed = false
      while i < n {
        let ch = chars[i]
        if ch == '>' {
          i += 1
          closed = true
          break
        }
        if ch == '\r' || ch == '\n' {
          raise @types.TextGridError::InvalidFormat(
            line=start_line,
            message="unterminated angle-bracket flag",
          )
        }
        sb.write_char(ch)
        i += 1
      }
      if !closed {
        raise @types.TextGridError::InvalidFormat(
          line=start_line,
          message="unterminated angle-bracket flag",
        )
      }
      let flag = sb.to_string().trim().to_owned()
      tokens.push({ kind: Flag(flag), line: start_line, })
      continue
    }
    if starts_number(chars, i) {
      let start_line = line
      let sb = StringBuilder()
      if chars[i] == '+' || chars[i] == '-' {
        sb.write_char(chars[i])
        i += 1
      }
      let mut has_digits = false
      while i < n && is_ascii_digit(chars[i]) {
        sb.write_char(chars[i])
        has_digits = true
        i += 1
      }
      if i < n && chars[i] == '.' {
        sb.write_char('.')
        i += 1
        while i < n && is_ascii_digit(chars[i]) {
          sb.write_char(chars[i])
          has_digits = true
          i += 1
        }
      }
      if !has_digits {
        raise @types.TextGridError::InvalidFormat(
          line=start_line,
          message="invalid numeric literal",
        )
      }
      if i < n && (chars[i] == 'e' || chars[i] == 'E') {
        sb.write_char(chars[i])
        i += 1
        if i < n && (chars[i] == '+' || chars[i] == '-') {
          sb.write_char(chars[i])
          i += 1
        }
        let mut exp_digits = false
        while i < n && is_ascii_digit(chars[i]) {
          sb.write_char(chars[i])
          exp_digits = true
          i += 1
        }
        if !exp_digits {
          raise @types.TextGridError::InvalidFormat(
            line=start_line,
            message="invalid exponent in numeric literal",
          )
        }
      }
      if i < n &&
        (is_ascii_alpha(chars[i]) || chars[i] == '.' || chars[i] == '_') {
        raise @types.TextGridError::InvalidFormat(
          line=start_line,
          message="unexpected suffix on numeric literal",
        )
      }
      tokens.push({ kind: Num(sb.to_string()), line: start_line, })
      continue
    }
    if is_ident_start(c) {
      while i < n && is_ident_cont(chars[i]) {
        i += 1
      }
      continue
    }
    raise @types.TextGridError::InvalidFormat(
      line~,
      message="unexpected character '\{c}'",
    )
  }
  tokens
}

///|
priv struct TokenCursor {
  tokens : Array[Token]
  mut pos : Int32
}

///|
fn TokenCursor::eof_line(self : TokenCursor) -> Int32 {
  let n = self.tokens.length()
  if n == 0 {
    1
  } else {
    self.tokens[n - 1].line
  }
}

///|
fn TokenCursor::peek(self : TokenCursor) -> Token? {
  if self.pos < self.tokens.length() {
    Some(self.tokens[self.pos])
  } else {
    None
  }
}

///|
fn TokenCursor::next(
  self : TokenCursor,
  expected : String,
) -> Token raise @types.TextGridError {
  if self.pos >= self.tokens.length() {
    raise @types.TextGridError::InvalidFormat(
      line=self.eof_line(),
      message="unexpected end of input; expected \{expected}",
    )
  }
  let tok = self.tokens[self.pos]
  self.pos += 1
  tok
}

///|
fn TokenCursor::expect_string(
  self : TokenCursor,
  expected : String,
) -> (String, Int32) raise @types.TextGridError {
  let tok = self.next(expected)
  match tok.kind {
    Str(s) => (s, tok.line)
    _ =>
      raise @types.TextGridError::InvalidFormat(
        line=tok.line,
        message="expected \{expected}",
      )
  }
}

///|
fn TokenCursor::expect_double(
  self : TokenCursor,
  expected : String,
) -> (Double, Int32) raise @types.TextGridError {
  let tok = self.next(expected)
  match tok.kind {
    Num(s) => {
      let v = @string.parse_double(s) catch {
        _ =>
          raise @types.TextGridError::InvalidFormat(
            line=tok.line,
            message="invalid floating-point number '\{s}' for \{expected}",
          )
      }
      if !v.is_finite() {
        raise @types.TextGridError::InvalidFormat(
          line=tok.line,
          message="non-finite number '\{s}' for \{expected}",
        )
      }
      (v, tok.line)
    }
    _ =>
      raise @types.TextGridError::InvalidFormat(
        line=tok.line,
        message="expected numeric \{expected}",
      )
  }
}

///|
fn TokenCursor::expect_int(
  self : TokenCursor,
  expected : String,
) -> (Int32, Int32) raise @types.TextGridError {
  let tok = self.next(expected)
  match tok.kind {
    Num(s) => {
      let v = @string.parse_int(s) catch {
        _ =>
          raise @types.TextGridError::InvalidFormat(
            line=tok.line,
            message="invalid integer '\{s}' for \{expected}",
          )
      }
      (v, tok.line)
    }
    _ =>
      raise @types.TextGridError::InvalidFormat(
        line=tok.line,
        message="expected integer \{expected}",
      )
  }
}

///|
fn TokenCursor::expect_nonneg_int(
  self : TokenCursor,
  expected : String,
) -> (Int32, Int32) raise @types.TextGridError {
  let (v, line) = self.expect_int(expected)
  if v < 0 {
    raise @types.TextGridError::InvalidFormat(
      line~,
      message="expected non-negative \{expected}, got \{v}",
    )
  }
  (v, line)
}

///|
fn parse_interval(
  cur : TokenCursor,
) -> @types.TextInterval raise @types.TextGridError {
  let (xmin, line) = cur.expect_double("interval xmin")
  let (xmax, _) = cur.expect_double("interval xmax")
  if xmin > xmax {
    raise @types.TextGridError::InvalidFormat(
      line~,
      message="interval xmin (\{xmin}) exceeds xmax (\{xmax})",
    )
  }
  let (text, _) = cur.expect_string("interval text")
  { xmin, xmax, text, }
}

///|
fn parse_point(
  cur : TokenCursor,
) -> @types.TextPoint raise @types.TextGridError {
  let (time, _) = cur.expect_double("point time")
  let (mark, _) = cur.expect_string("point mark")
  { time, mark, }
}

///|
fn parse_tier_header(
  cur : TokenCursor,
) -> (String, String, Double, Double, Int32) raise @types.TextGridError {
  let (tier_class, line) = cur.expect_string("tier class")
  let (tier_name, _) = cur.expect_string("tier name")
  let (tmin, _) = cur.expect_double("tier xmin")
  let (tmax, _) = cur.expect_double("tier xmax")
  if tmin > tmax {
    raise @types.TextGridError::InvalidFormat(
      line~,
      message="tier xmin (\{tmin}) exceeds xmax (\{tmax})",
    )
  }
  (tier_class, tier_name, tmin, tmax, line)
}

///|
fn parse_standard_tiers(
  cur : TokenCursor,
) -> Array[@types.TextGridTier] raise @types.TextGridError {
  let (n_tiers, _) = cur.expect_nonneg_int("tier count")
  let tiers : Array[@types.TextGridTier] = []
  for _ in 0..<n_tiers {
    let (tier_class, name, xmin, xmax, line) = parse_tier_header(cur)
    let (count, _) = cur.expect_nonneg_int("tier item count")
    if tier_class == "IntervalTier" {
      let intervals : Array[@types.TextInterval] = []
      for _ in 0..<count {
        intervals.push(parse_interval(cur))
      }
      tiers.push(
        @types.TextGridTier::Intervals({ name, xmin, xmax, intervals, }),
      )
    } else if tier_class == "TextTier" {
      let points : Array[@types.TextPoint] = []
      for _ in 0..<count {
        points.push(parse_point(cur))
      }
      tiers.push(@types.TextGridTier::Points({ name, xmin, xmax, points, }))
    } else {
      raise @types.TextGridError::InvalidFormat(
        line~,
        message="unknown tier class '\{tier_class}'",
      )
    }
  }
  tiers
}

///|
fn parse_chronological_tiers(
  cur : TokenCursor,
) -> Array[@types.TextGridTier] raise @types.TextGridError {
  let (n_tiers, _) = cur.expect_nonneg_int("chronological tier count")
  let tiers : Array[@types.TextGridTier] = []
  for _ in 0..<n_tiers {
    let (tier_class, name, xmin, xmax, line) = parse_tier_header(cur)
    if tier_class == "IntervalTier" {
      tiers.push(
        @types.TextGridTier::Intervals({ name, xmin, xmax, intervals: [], }),
      )
    } else if tier_class == "TextTier" {
      tiers.push(@types.TextGridTier::Points({ name, xmin, xmax, points: [], }))
    } else {
      raise @types.TextGridError::InvalidFormat(
        line~,
        message="unknown tier class '\{tier_class}'",
      )
    }
  }
  while cur.peek() is Some(_) {
    let (tier_idx, line) = cur.expect_int("chronological tier index")
    if tier_idx < 1 || tier_idx > n_tiers {
      raise @types.TextGridError::InvalidFormat(
        line~,
        message="chronological tier index \{tier_idx} out of range 1..\{n_tiers}",
      )
    }
    match tiers[tier_idx - 1] {
      Intervals(t) => t.intervals.push(parse_interval(cur))
      Points(t) => t.points.push(parse_point(cur))
    }
  }
  tiers
}

///|
/// Parse a Praat `.TextGrid` string in Long, Short, or Chronological
/// `ooTextFile` format.
pub fn parse_textgrid(
  input : String,
) -> @types.TextGrid raise @types.TextGridError {
  let tokens = tokenize(input)
  let cur : TokenCursor = { tokens, pos: 0, }
  let (file_type, ft_line) = cur.expect_string("file type \"ooTextFile\"")
  if file_type != "ooTextFile" {
    raise @types.TextGridError::InvalidFormat(
      line=ft_line,
      message="expected file type \"ooTextFile\", got \"\{file_type}\"",
    )
  }
  let (object_class, oc_line) = cur.expect_string("object class \"TextGrid\"")
  if object_class != "TextGrid" {
    raise @types.TextGridError::InvalidFormat(
      line=oc_line,
      message="expected object class \"TextGrid\", got \"\{object_class}\"",
    )
  }
  let (xmin, dom_line) = cur.expect_double("TextGrid xmin")
  let (xmax, _) = cur.expect_double("TextGrid xmax")
  if xmin > xmax {
    raise @types.TextGridError::InvalidFormat(
      line=dom_line,
      message="TextGrid xmin (\{xmin}) exceeds xmax (\{xmax})",
    )
  }
  let tiers = match cur.peek() {
    Some({ kind: Flag("absent"), .. }) => {
      ignore(cur.next("tiers flag"))
      []
    }
    Some({ kind: Flag("exists"), .. }) => {
      ignore(cur.next("tiers flag"))
      parse_standard_tiers(cur)
    }
    Some({ kind: Flag(other), line, }) =>
      raise @types.TextGridError::InvalidFormat(
        line~,
        message="unexpected tiers flag <\{other}>",
      )
    Some({ kind: Num(_), .. }) => parse_chronological_tiers(cur)
    Some({ line, .. }) =>
      raise @types.TextGridError::InvalidFormat(
        line~,
        message="expected <exists>, <absent>, or tier count",
      )
    None =>
      raise @types.TextGridError::InvalidFormat(
        line=cur.eof_line(),
        message="unexpected end of input after TextGrid domain",
      )
  }
  if cur.peek() is Some(extra) {
    raise @types.TextGridError::InvalidFormat(
      line=extra.line,
      message="unexpected trailing token",
    )
  }
  { xmin, xmax, tiers, }
}

///|
fn escape_tg_string(s : String) -> String {
  s.replace_all(old="\"", new="\"\"")
}

///|
/// Serialize a `TextGrid` back to Praat `ooTextFile` format (Long format
/// by default, or Short format when `short=true`).
pub fn to_textgrid_string(
  tg : @types.TextGrid,
  short~ : Bool = false,
) -> String {
  let sb = StringBuilder()
  if short {
    sb <+ "\"ooTextFile\"\n"
    sb <+ "\"TextGrid\"\n"
    sb <+ "\{tg.xmin}\n"
    sb <+ "\{tg.xmax}\n"
    sb <+ "<exists>\n"
    sb <+ "\{tg.tiers.length()}\n"
    for tier in tg.tiers {
      match tier {
        Intervals(t) => {
          sb <+ "\"IntervalTier\"\n"
          sb <+ "\"\{escape_tg_string(t.name)}\"\n"
          sb <+ "\{t.xmin}\n"
          sb <+ "\{t.xmax}\n"
          sb <+ "\{t.intervals.length()}\n"
          for iv in t.intervals {
            sb <+ "\{iv.xmin}\n"
            sb <+ "\{iv.xmax}\n"
            sb <+ "\"\{escape_tg_string(iv.text)}\"\n"
          }
        }
        Points(t) => {
          sb <+ "\"TextTier\"\n"
          sb <+ "\"\{escape_tg_string(t.name)}\"\n"
          sb <+ "\{t.xmin}\n"
          sb <+ "\{t.xmax}\n"
          sb <+ "\{t.points.length()}\n"
          for pt in t.points {
            sb <+ "\{pt.time}\n"
            sb <+ "\"\{escape_tg_string(pt.mark)}\"\n"
          }
        }
      }
    }
    return sb.to_string()
  }
  sb <+ "File type = \"ooTextFile\"\n"
  sb <+ "Object class = \"TextGrid\"\n\n"
  sb <+ "xmin = \{tg.xmin} \n"
  sb <+ "xmax = \{tg.xmax} \n"
  sb <+ "tiers? <exists> \n"
  sb <+ "size = \{tg.tiers.length()} \n"
  sb <+ "item []: \n"
  for i, tier in tg.tiers {
    let idx = i + 1
    sb <+ "    item [\{idx}]:\n"
    match tier {
      Intervals(t) => {
        sb <+ "        class = \"IntervalTier\" \n"
        sb <+ "        name = \"\{escape_tg_string(t.name)}\" \n"
        sb <+ "        xmin = \{t.xmin} \n"
        sb <+ "        xmax = \{t.xmax} \n"
        sb <+ "        intervals: size = \{t.intervals.length()} \n"
        for j, iv in t.intervals {
          let j_idx = j + 1
          sb <+ "        intervals [\{j_idx}]:\n"
          sb <+ "            xmin = \{iv.xmin} \n"
          sb <+ "            xmax = \{iv.xmax} \n"
          sb <+ "            text = \"\{escape_tg_string(iv.text)}\" \n"
        }
      }
      Points(t) => {
        sb <+ "        class = \"TextTier\" \n"
        sb <+ "        name = \"\{escape_tg_string(t.name)}\" \n"
        sb <+ "        xmin = \{t.xmin} \n"
        sb <+ "        xmax = \{t.xmax} \n"
        sb <+ "        points: size = \{t.points.length()} \n"
        for j, pt in t.points {
          let j_idx = j + 1
          sb <+ "        points [\{j_idx}]:\n"
          sb <+ "            number = \{pt.time} \n"
          sb <+ "            mark = \"\{escape_tg_string(pt.mark)}\" \n"
        }
      }
    }
  }
  sb.to_string()
}
