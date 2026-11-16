// SPDX-License-Identifier: AGPL-3.0-only
//! Minimal JSON reader for conformance vectors, so tests need no dependency.

#[derive(Debug)]
pub enum Value {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Value>),
    Obj(Vec<(String, Value)>),
}

impl Value {
    pub fn get(&self, key: &str) -> &Value {
        let Value::Obj(fields) = self else {
            panic!("not an object looking up {key}")
        };
        let found = fields.iter().find(|(k, _)| k == key);
        &found.unwrap_or_else(|| panic!("missing key {key}")).1
    }

    pub fn num(&self) -> f64 {
        let Value::Num(n) = self else {
            panic!("not a number: {self:?}")
        };
        *n
    }

    pub fn boolean(&self) -> bool {
        let Value::Bool(b) = self else {
            panic!("not a bool: {self:?}")
        };
        *b
    }

    pub fn str(&self) -> &str {
        let Value::Str(s) = self else {
            panic!("not a string: {self:?}")
        };
        s
    }

    pub fn arr(&self) -> &[Value] {
        let Value::Arr(items) = self else {
            panic!("not an array: {self:?}")
        };
        items
    }
}

pub fn parse(text: &str) -> Result<Value, String> {
    let mut parser = Parser {
        bytes: text.as_bytes(),
        pos: 0,
    };
    let value = parser.value()?;
    parser.skip_ws();
    match parser.pos == parser.bytes.len() {
        true => Ok(value),
        false => Err(format!("trailing data at {}", parser.pos)),
    }
}

struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl Parser<'_> {
    fn skip_ws(&mut self) {
        while self.pos < self.bytes.len() && self.bytes[self.pos].is_ascii_whitespace() {
            self.pos += 1;
        }
    }

    fn peek(&mut self) -> Option<u8> {
        self.skip_ws();
        self.bytes.get(self.pos).copied()
    }

    fn expect(&mut self, byte: u8) -> Result<(), String> {
        match self.peek() == Some(byte) {
            true => {
                self.pos += 1;
                Ok(())
            }
            false => Err(format!("expected '{}' at {}", byte as char, self.pos)),
        }
    }

    fn value(&mut self) -> Result<Value, String> {
        match self.peek() {
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'"') => self.string().map(Value::Str),
            Some(b't') => self.literal("true", Value::Bool(true)),
            Some(b'f') => self.literal("false", Value::Bool(false)),
            Some(b'n') => self.literal("null", Value::Null),
            _ => self.number(),
        }
    }

    fn literal(&mut self, word: &str, value: Value) -> Result<Value, String> {
        let end = self.pos + word.len();
        match self.bytes.get(self.pos..end) == Some(word.as_bytes()) {
            true => {
                self.pos = end;
                Ok(value)
            }
            false => Err(format!("bad literal at {}", self.pos)),
        }
    }

    fn number(&mut self) -> Result<Value, String> {
        let start = self.pos;
        let is_num = |b: &u8| b.is_ascii_digit() || b"+-.eE".contains(b);
        while self.bytes.get(self.pos).is_some_and(is_num) {
            self.pos += 1;
        }
        let text = std::str::from_utf8(&self.bytes[start..self.pos]).map_err(|e| e.to_string())?;
        text.parse()
            .map(Value::Num)
            .map_err(|_| format!("bad number at {start}"))
    }

    fn string(&mut self) -> Result<String, String> {
        self.expect(b'"')?;
        let mut out = Vec::new();
        while let Some(&b) = self.bytes.get(self.pos) {
            self.pos += 1;
            match b {
                b'"' => return String::from_utf8(out).map_err(|e| e.to_string()),
                b'\\' => {
                    out.push(self.bytes[self.pos]);
                    self.pos += 1;
                }
                _ => out.push(b),
            }
        }
        Err("unterminated string".to_string())
    }

    fn array(&mut self) -> Result<Value, String> {
        self.expect(b'[')?;
        let mut items = Vec::new();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(Value::Arr(items));
        }
        loop {
            items.push(self.value()?);
            if self.peek() == Some(b']') {
                self.pos += 1;
                return Ok(Value::Arr(items));
            }
            self.expect(b',')?;
        }
    }

    fn object(&mut self) -> Result<Value, String> {
        self.expect(b'{')?;
        let mut fields = Vec::new();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(Value::Obj(fields));
        }
        loop {
            self.skip_ws();
            let key = self.string()?;
            self.expect(b':')?;
            fields.push((key, self.value()?));
            if self.peek() == Some(b'}') {
                self.pos += 1;
                return Ok(Value::Obj(fields));
            }
            self.expect(b',')?;
        }
    }
}
