# Instructions for Backend Contest

## Challenge
Your team and/or you need to develop a backend that intermediates payment requests to a payment processing service, called Payment Processor.

![diagram](misc/imgs/instrucoes/image-01.png)

For each intermediated payment, a financial fee is charged. For example, with a 5% fee for a payment request of $100.00; you would be charged $5.00 and keep $95.00.

However, since real life is tough, this service will suffer instabilities. Its response times may become very high and it may even become unavailable, responding with HTTP 500 errors. And since we know life is tough, we prepared for these things and created a plan B. Plan B is that there is a second Payment Processor service.

![diagram](misc/imgs/instrucoes/image-02.png)

**Note**: The fees on payment processing will not change during testing and the default service will always have the lowest fee.

The problem is that this contingency service – called Payment Processor Fallback – charges a higher fee on payments. And it can also suffer instabilities and unavailability! In fact, both services can be unstable and/or unavailable at the same time, because life is like that...

#### Nothing is so bad that it can't get worse...

In addition to the `POST /payments` endpoint, it's also necessary to provide an endpoint that details the summary of processed payments – `GET /payments-summary`. This endpoint will be used to audit consistency between what was processed by your backend and what was processed by the two Payment Processors. It's the Central Bank checking if you're recording everything correctly from time to time.

![diagram](misc/imgs/instrucoes/image-03.png)

These periodic calls during the Contest test will compare responses and, for each inconsistency, a hefty fine will be applied!

#### Life is a Roller Coaster Indeed...

To make your life easier and verify the availability of Payment Processors, each of them provides a **health-check** endpoint – `GET /payments/service-health` – that shows if the service is experiencing failures and what is the minimum response time for payment processing. However, this endpoint has a limit of one call every five seconds. If this limit is exceeded, an `HTTP 429 - Too Many Requests` response will be returned. You can use these endpoints to develop the best strategy to pay the lowest possible fee.

## Scoring

The Backend Contest scoring criterion will be how much profit your backend managed to have at the end of the test. That is, the more payments you make with the lowest financial fee, the better. Remember that if there are inconsistencies detected by the Central Bank, you will have to pay a fine of 35% on the total profit.

There is also a technical criterion for scoring. If your backend and Payment Processors have very fast response times, you can also score points. The metric used for performance will be p99 (we'll take the 1% worst response times - 99th percentile). From a p99 of 10ms or less, you receive a bonus on your total profit of 2% for each 1ms below 11ms.

The formula for the performance bonus percentage is `(11 - p99) * 0.02`. If the value is negative, the bonus is 0% – there is no penalty for results with p99 greater than 11ms.

Examples:
- p99 of 10ms = 2% bonus
- p99 of 9ms = 4% bonus
- p99 of 5ms = 12% bonus
- p99 of 1ms = 20% bonus

*¹ The percentile will be calculated over all HTTP requests made in the test and not just over requests made to your backend.*

*² All payments will have exactly the same value – random values will not be generated.*

## Architecture, Restrictions and Submission

Your backend should follow the following architecture/restrictions.

**Web Servers**: Have at least two web server instances that will respond to `POST /payments` and `GET /payments-summary` requests. That is, some form of load distribution should occur (usually through a load balancer like nginx, for example).

**Containerization**: You should provide your backend in docker compose format. All images declared in docker compose (`docker-compose.yml`) should be publicly available in image registries (https://hub.docker.com/ for example).

You should restrict CPU and Memory usage to 1.5 CPU units and 350MB of memory across all declared services as desired through the `deploy.resources.limits.cpus` and `deploy.resources.limits.memory` attributes as in the following snippet example.

