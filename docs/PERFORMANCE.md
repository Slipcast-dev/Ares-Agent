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
