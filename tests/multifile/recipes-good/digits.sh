cat >> "$1" <<'EOS'

pub fn tok_digits(n: int) -> [] int {
    var d = 1;
    var m = n;
    while m >= 10 {
        m = m / 10;
        d = d + 1;
    }
    return d;
}
EOS
