# Composer install hang — root cause

## TL;DR

It is a **PHP opcache JIT (`opcache.jit=tracing`) miscompilation bug**, not a Composer bug. The exact PHP ini values (`ini-values: "memory_limit=-1, phar.readonly=0, opcache.enable_cli=1, opcache.jit=tracing, opcache.jit_buffer_size=64M"`) trigger it.

The miscompiled function is `Composer\DependencyResolver\RuleSetGenerator::addRulesForPackage` — specifically the `isset($this->addedMap[$package->id])` short-circuit at the top of the work-queue loop ([RuleSetGenerator.php#L169](https://github.com/composer/composer/blob/2.9.7/src/Composer/DependencyResolver/RuleSetGenerator.php#L169), inside the loop at [L167–L173](https://github.com/composer/composer/blob/2.9.7/src/Composer/DependencyResolver/RuleSetGenerator.php#L167-L173)). JIT-compiled code for that `isset` returns false even after `$this->addedMap[$package->id] = $package;` was just executed for the same key. So packages keep being re-enqueued and re-processed forever, rules and memory grow without bound, and the 10-minute CI timeout kills it.

Reproduced locally in Docker on this anonymized bundle (PHP 8.5.6, Composer 2.9.5, the `composer.json` / `composer.lock` / `core/` shipped here):

| `opcache.jit` | runs | hangs | rate |
|---------------|-----:|------:|-----:|
| tracing       |  500 |    19 |  3.8% |
| function      |  100 |     0 |    0% |
| off           |  200 |     0 |    0% |

The rate is order-of-magnitude lower than the unanonymized real-world project that originally hit this in CI (~20% rate on a fatter lock file) — the same bug, the same bytecode site, but a smaller / slightly differently-shaped pool means the JIT picks the bad trace less often. **Plan for variance**: at 3.8%, the probability of seeing zero hangs in 50 runs is `(1 − 0.038)^50 ≈ 14%`. Run 200+ iterations for a reliable demonstration.

## Smoking gun

Patched RuleSetGenerator to log every 5000 work-queue iterations and to re-check `isset` *after* the iter++ branch:

```
[HANGPROBE] iter=17455000 skipped=0 addedMap=96 rules=181 queueLen=5 mem=399MB
            lastPkg=ext-fileinfo@8.4.21.0 id=17 objId=8408
            inMap=YES mapHasObjId=8408 firstKeys=[1,2,3,4,5,6,7,8,9,10,11,12]
```

Read this carefully:

- `skipped=0` → the `continue` branch (`if (isset($this->addedMap[$package->id])) continue;`) was **never taken** in 17 million iterations.
- `inMap=YES mapHasObjId=8408` → my re-check of the same `isset(...)` *3 lines later*, in the iter++ branch, sees the key with the same object id (8408).
- `addedMap=96 firstKeys=[1..12]` → the key `17` is sitting in the map, has been for a while.

There is **no code between the two isset checks** that mutates `$this->addedMap` or `$package->id`. Only `$iter++` and a `% 5000` log block. The first isset is wrong; the second is right. JIT-only behaviour. Reproducibly disappears with `opcache.jit=off` or `opcache.jit=function`.

The packages stuck in the cycle are always the same: `php`, `ext-fileinfo`, `league/flysystem`, `league/flysystem-local`, `league/mime-type-detection` (the deps of `league/flysystem-local`). Whichever traced loop the JIT compiled in this run, that trace covers this iteration pattern.

## Reproducer

`Dockerfile.jit`, `Dockerfile.nojit`, `loop.sh`, plus a `composer.json` / `composer.lock` / `core/` triple that reproduces the bug on its own. `cd` here first, then:

```bash
# Build both images (PHP 8.5.6 + Composer 2.9.5)
docker build -t composer-jit-hang  -f Dockerfile.jit  .
docker build -t composer-jit-nojit -f Dockerfile.nojit .

# 1) See the hang with opcache.jit=tracing.
#    loop.sh bootstraps vendor/ on first run (one ~30 s install to bring in
#    Symfony Flex, which has to be loaded as a plugin for the JIT bug to
#    fire), then runs `composer install --dry-run` 200 times. Expect a
#    handful of those runs to be killed at the 15 s deadline — last
#    measurement: 19 hangs in 500 runs.
docker run --rm \
  -v "$PWD":/work \
  composer-jit-hang bash /loop.sh 200

# 2) Same project, same Composer, same PHP, JIT off — zero hangs.
docker run --rm \
  -v "$PWD":/work \
  composer-jit-nojit bash /loop.sh 200
```

### What's in this directory

- `composer.json` / `composer.lock` — a Symfony-Flex-using project, modelled after a real one that hangs in CI. Repository URLs and any non-public package names have been replaced with `composer.example.invalid` and `repro/…`; only public packages from packagist.org remain referenced.
- `core/composer.json` — stub for the local-path package the project declares as a `path` repo. Empty body, just metadata.
- `loop.sh` — bootstraps `vendor/` once, then loops `composer install --dry-run`.
- `Dockerfile.jit` / `Dockerfile.nojit` — PHP 8.5 + Composer 2.9.5, with `opcache.jit=tracing` vs `opcache.jit=off` being the only difference.
