# Производительность / Performance

Idle queue supervision60s; active/error1s; accepted work is not interrupted to
save energy. On battery, Low Power, constrained thermal or unknown power source,
at most one heavy callback starts concurrently. Existing work finishes normally.
FIFO is retained: a queued heavy head may delay light work behind it.

Арес кэширует чистые представления одного снимка, но проверяет свежесть и доступ
перед каждой страницей. Афина использует bounded top-K и адаптивный monitor timer;
скрытый dashboard не опрашивает метрики. Battery drain и реальные переходы AC/Low
Power требуют отдельной аппаратной проверки. CPU/RSS/kernel wakeups измеряются
только в явно указанном synthetic runtime workload; гарантий экономии батареи нет.

## Исторический замер 0.28.0 / Historical measurement

0.28.0, macOS27.0.1 arm64, release runtime copies, empty synthetic profile,
no GUI/model,65-second window, native proc_pid_rusage with calibrated Mach
time conversion. Ares:0.0714% single-core CPU,35.2MiB peak RSS,34 interrupt
wakeups. Athena:0.0054%,37.5MiB,7 interrupt wakeups. One run only; kernel wakeup
counters are not Mac sleep events. No battery-drain or energy-saving percentage
is claimed. Additional synthetic5000-file scans completed on both runtimes.

Эти числа относятся только к0.28.0 и не являются замером0.37.0.
These numbers describe0.28.0 only; no equivalent0.37.0 measurement is claimed.
