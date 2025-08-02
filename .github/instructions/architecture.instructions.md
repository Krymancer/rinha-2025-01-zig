# Architecture and Deployment Instructions for Rinha de Backend

This document describes the proposed architecture and detailed instructions for deploying a high-performance backend system, optimized for the "Rinha de Backend 2025" challenge. The solution uses Docker Compose for orchestration, HAProxy for load balancing, PostgreSQL for transactional data persistence, and Redis for message queues and caching, with application logic developed in Zig.

## Architecture Overview

The architecture consists of the following containerized services:

  * **HAProxy**: Acts as a load balancer, distributing HTTP requests to Zig application instances.[1]
  * **Zig Application (2 instances)**: The main backend that processes payment requests, interacts with Redis and PostgreSQL, and manages communication with external Payment Processors.
  * **PostgreSQL**: Relational database for persistent transaction storage.[2, 3, 4]
  * **Redis**: Used as a message queue for asynchronous payment processing and as an in-memory cache.[5, 6, 7]

## Docker Compose Configuration (`docker-compose.yml`)

The `docker-compose.yml` file defines and orchestrates all services.[8, 9] It is crucial that resource limits (CPU and memory) are strictly respected to meet Rinha de Backend requirements (total of 1.5 CPU and 350MB memory for all services).[9, 4]

