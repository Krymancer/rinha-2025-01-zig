# Benchmark Instructions

We can benchmark everthing to see if the implementation is going ok, we will do that using k6, but first we need to have the payment processing running, for each tests they will have to been recreated so going to `./payment-processor` and running `docker compose down` and `docker compose up -d --force-recreate` is necessary

After that we can run the application container in the root folder we need to update the docker image and `docker compose pull` to pull the latest image and `docker compose up` to run it.

Now we can Just ran the benchmark going to the `rinha-test` directory and runnin `k6 run -e MAX_REQUESTS=550 -e PARTICIPANT=krymancer -e TOKEN=123 --log-output=file=k6.logs rinha.js`

Make sure to view the logs after and make sure at least the the application has not having timeouts