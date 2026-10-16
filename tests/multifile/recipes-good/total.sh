cat >> "$1" <<'EOS'

fn app_total(n: int) -> [] int {
    return store.store_cost(n) + 1;
}
EOS
