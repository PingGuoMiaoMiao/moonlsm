# moonkv 适配器（对照用，不参与本项目构建）

`BENCHMARK.md` §3.5 那张「moonlsm vs moonkv」的表，是用**同一个驱动脚本**
（`benches/python/bench.py`）跑出来的。这个目录里就是让 moonkv 能被那个脚本
驱动的适配器。

## 为什么要适配器

直接比两个库的 API 没有意义 —— 量到的会是「谁家的调用方式更省事」。
要比就得让两边跑同一套脚本、同一个 workload、同一种协议（一行 JSON 一条命令）。
所以这里照 `cmd/dbcli` 的协议实现了一遍 moonkv 的壳。

## 为什么不放进模块里

`benches/moon/moonkv_cli/` 如果直接放 `main.mbt` + `moon.pkg`，它就成了
本模块的一个包，`moon build` 会去编它，于是 `moon.mod` 里要加
`wallll-wal6/moonkv` 依赖 —— **发布到 mooncakes 的包里会多一个跟本库无关的依赖**。
所以这两个文件带 `.txt` 后缀，只作为源码存档，构建系统看不见它们。

## 怎么跑

```bash
mkdir -p /tmp/moonkv-cli && cd /tmp/moonkv-cli
printf 'name = "probe/moonkvcli"\nversion = "0.0.1"\n' > moon.mod
cp <repo>/benches/moon/moonkv_cli/main.mbt.txt main.mbt
cp <repo>/benches/moon/moonkv_cli/moon.pkg.txt moon.pkg
moon add wallll-wal6/moonkv
moon build --target native --release

cd <repo>/benches/python
python bench.py \
  --cmd "/tmp/moonkv-cli/_build/native/release/build/moonkvcli.exe" \
  --data-dir ./data-mkv --n 10000 --batch 1000 --reads 5000
```

适配器读环境变量 `MOONLSM_DATA`（`bench.py` 通过 `dbcli_launch.child_env`
设的就是这一个），所以驱动脚本一行都不用改。

## 它刻意没做的事

| 没做 | 原因 |
|---|---|
| `sync` 开关 | moonkv 0.1.3 的 `put` 是 `fopen(ab)`+`fwrite`+`fflush`+`fclose`，没有 `fsync`。它没有「持久化级别」这个概念，所以也没有可开关的东西 |
| 组提交 | moonkv 的 API 没有批量写，一次 `put` 就是一次落盘调用 |
| 正确性判断 | 适配器把 `get` 的所有错误都折成「没取到」。基准只跑成功路径；**不要**拿它判断 moonkv 对不对 |
