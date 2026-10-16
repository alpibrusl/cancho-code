cat >> "$1" <<'EOS'

pub fn store_cost(n: int) -> [] int {
    return parser.parse_width(n) * 2;
}
EOS
