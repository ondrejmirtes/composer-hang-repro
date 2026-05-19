#!/bin/bash
# Run `composer install --dry-run` N times against /work, kill any run that
# exceeds 15 seconds, report ok/hang counts.
#
# /work is expected to contain the repro project (the composer.json /
# composer.lock / core/ from this bundle). On first run vendor/ is populated
# with Symfony Flex etc., which is needed for the JIT bug to trigger (Flex
# hooks PRE_POOL_CREATE and the bad JIT trace passes through that path).
set -u
cd /work

# Cooperate with running as root inside the container.
export COMPOSER_ALLOW_SUPERUSER=1

if [ ! -f vendor/symfony/flex/composer.json ]; then
  echo "--- bootstrapping vendor/ (one-time) ---"
  # The composer.json declares a composer-type repo at composer.example.invalid,
  # which is unreachable on purpose — install-verify never queries it because
  # the locked repo has every package metadata it needs. Its presence in the
  # RepositorySet is what makes JIT trace the bad path.
  composer install --no-progress --no-scripts --no-autoloader --classmap-authoritative --prefer-dist -q 2>&1 | tail -5
  if [ ! -f vendor/symfony/flex/composer.json ]; then
    echo "ERROR: vendor/symfony/flex was not installed. The JIT bug needs Flex loaded as a plugin."
    exit 1
  fi
  echo "--- vendor ready ---"
fi

N=${1:-50}
ok=0; hangs=0
for i in $(seq 1 $N); do
  START=$(date +%s)
  composer install --no-progress --profile --classmap-authoritative --prefer-dist --dry-run -q > /dev/null 2>&1 &
  PID=$!
  while kill -0 $PID 2>/dev/null; do
    if [ $(( $(date +%s) - START )) -gt 15 ]; then
      kill -9 $PID
      hangs=$((hangs+1))
      echo "HANG iter=$i"
      break
    fi
    sleep 0.2
  done
  wait $PID 2>/dev/null
  rc=$?
  if [ $rc -eq 0 ]; then ok=$((ok+1)); fi
done
echo "Result: ok=$ok hangs=$hangs / $N (PHP $(php -r 'echo PHP_VERSION;'), opcache.jit=$(php -r 'echo ini_get("opcache.jit");'))"
