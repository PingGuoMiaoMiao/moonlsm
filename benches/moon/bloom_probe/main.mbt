///|
/// bloom filter 的误判率对照实验。
///
/// **为什么需要这个工具。** 「每元素 10 bit、7 个哈希」是文献里的经验值，
/// 但经验值不能证明我的实现真的达到了那个误判率 —— 哈希函数、双哈希构造、
/// 取模方式任何一处写歪，误判率就会悄悄涨上去，而功能测试一条都发现不了
/// （假阳性不影响正确性，只浪费 IO）。
///
/// 这个程序把「参数 → 实测误判率」的对应关系打出来，用于：
///
/// 1. 确认实现与理论吻合（差一个数量级说明实现有 bug）
/// 2. 回答「为什么是 10 bit 而不是 8 或 12」—— 用这张表，不用经验
///
/// 运行：`moon run benches/moon/bloom_probe --target native`

///|
fn pad(i : Int, width : Int) -> String {
  let s = i.to_string()
  let mut out = ""
  for _ in 0..<(width - s.length()) {
    out = out + "0"
  }
  out + s
}

///|
/// 生成 `n` 条互不相同的 key。前缀不同就得到两个不相交的集合，
/// 一个写进 filter，一个拿来问 —— 后者必然「不在」，
/// 所以任何一次「可能在」都是误判。
fn keys(prefix : String, n : Int) -> Array[Bytes] {
  let out : Array[Bytes] = []
  for i in 0..<n {
    out.push(@utf8.encode(prefix + pad(i, 8)))
  }
  out
}

///|
fn measure(bits_per_key : Int, k : Int, n : Int, probes : Int) -> Double {
  let f = @moonlsm.BloomFilter::new_with(n, bits_per_key, k)
  for key in keys("p:", n) {
    f.put(key)
  }
  let mut hit = 0
  for key in keys("a:", probes) {
    if f.may_contain(key) {
      hit = hit + 1
    }
  }
  hit.to_double() / probes.to_double()
}

///|
/// 保留三位小数、单位 %。
fn fmt_pct(x : Double) -> String {
  let scaled = (x * 100000.0).to_int()
  ip_frac(scaled, 1000)
}

///|
/// 把 `scaled / div` 打印成保留三位的定点数。
fn ip_frac(scaled : Int, div : Int) -> String {
  (scaled / div).to_string() + "." + pad(scaled % div, 3)
}

///|
/// 理论误判率 `(1 - e^(-k*n/m))^k`，其中 `m/n = bits_per_key`。
/// 用泰勒展开算 `e^x` 不够稳，这里直接用 `exp` 的级数在 `[-1, 0]` 上算，
/// 20 项足够到 1e-16。
fn theory(bits_per_key : Int, k : Int) -> Double {
  let bpk = bits_per_key.to_double()
  let kd = k.to_double()
  // e^(-k/bpk)
  let x = -kd / bpk
  let mut term = 1.0
  let mut sum = 1.0
  for i in 1..<20 {
    term = term * x / i.to_double()
    sum = sum + term
  }
  // (1 - e^x)^k
  let base = 1.0 - sum
  let mut acc = 1.0
  for _ in 0..<k {
    acc = acc * base
  }
  acc
}

///|
fn main {
  let n = 10000
  let probes = 100000
  // 先做分布诊断：k=1 时「置位数 / 插入数」应该接近 1（几乎不撞），
  // 明显小于 1 就说明探测位置在聚簇，后面所有误判率都不可信。
  println("### 哈希分布诊断")
  println("")
  for bpk in [4, 10, 20] {
    let f = @moonlsm.BloomFilter::new_with(n, bpk, 1)
    for key in keys("p:", n) {
      f.put(key)
    }
    let bits = f.num_bits()
    // 理论置位数 m*(1-e^(-n/m))
    let x = -(n.to_double()) / bits.to_double()
    let mut term = 1.0
    let mut sum = 1.0
    for i in 1..<20 {
      term = term * x / i.to_double()
      sum = sum + term
    }
    let expect = bits.to_double() * (1.0 - sum)
    println("bits/key=" + bpk.to_string() + "  num_bits=" + bits.to_string() +
      "  实际置位=" + f.popcount().to_string() + "  理论置位=" +
      expect.to_int().to_string() + "  比值=" +
      (f.popcount().to_double() / expect).to_string())
  }
  println("")
  println("bloom filter 误判率对照（n = " + n.to_string() + " 个 key，" +
    probes.to_string() + " 次不存在查询）")
  println("")
  println("| bits/key | k | filter 字节 | 实测误判率 | 理论误判率 | 偏差 |")
  println("|---:|---:|---:|---:|---:|---:|")
  let bpks : Array[Int] = [4, 6, 8, 10, 12, 16, 20]
  for bpk in bpks {
    // 最优 k = bits_per_key * ln2
    let k = ((bpk.to_double() * 0.6931) + 0.5).to_int()
    let kk = if k < 1 { 1 } else { k }
    let measured = measure(bpk, kk, n, probes)
    let theo = theory(bpk, kk)
    let bytes = 1 + 3 + n * bpk / 8
    let ratio = measured / theo
    println("| " + bpk.to_string() + " | " + kk.to_string() + " | " +
      bytes.to_string() + " | " + fmt_pct(measured) + "% | " + fmt_pct(theo) +
      "% | " + ip_frac((ratio * 1000.0).to_int(), 1000) + "x |")
  }
  println("")
  println("### 固定 10 bit，只改 k")
  println("")
  println("| k | 实测误判率 | 理论误判率 |")
  println("|---:|---:|---:|")
  let ks : Array[Int] = [1, 2, 3, 4, 5, 6, 7, 8, 10, 12]
  for k in ks {
    let measured = measure(10, k, n, probes)
    println("| " + k.to_string() + " | " + fmt_pct(measured) + "% | " +
      fmt_pct(theory(10, k)) + "% |")
  }
}
