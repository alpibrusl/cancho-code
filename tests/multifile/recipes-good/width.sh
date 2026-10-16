cat >> "$1" <<'EOS'

pub fn parse_width(n: int) -> [] int {
    return tokens.tok_digits(n) + 1;
}
EOS
