# Rinha de Backend 2025 - Zig

## Overview

This project is a high-performance payment processing API developed for the Rinha de Backend 2025 competition. Built in Zig, it focuses on maximizing throughput and resource efficiency using advanced optimization techniques.

## Architecture

- **Clustered APIs**: Two containers (`api1` and `api2`) run the same application, communicating via Unix Sockets for ultra-low network overhead.
- **Nginx Load Balancer**: Routes requests to containers via sockets for optimal performance.
- **Worker Threads**: Payment processing is handled by worker threads, enabling efficient multi-core utilization.
- **Bit Packing**: In-memory payment storage uses bit packing to minimize memory usage and accelerate queries.
- **Inter-instance Communication**: Each instance queries the "foreign state" of the other for global summarization via internal HTTP.

## Performance Techniques

- **Unix Sockets**: Local communication between Nginx and APIs via sockets reduces latency and TCP overhead.
- **Bit Packing**: Payments stored as packed integers, optimizing memory usage and cache performance.
- **Lock-free Queues**: Atomic operations for high-throughput message processing.
- **Worker Threads**: Parallel payment processing without blocking the main event loop.
- **Zero Heavy Dependencies**: Minimal dependencies using Zig's standard library for maximum performance.

## Endpoints

- `POST /payments`: Enqueues a new payment for processing.
- `GET /payments-summary`: Returns payment summary (local and global).
- `POST /purge-payments`: Clears in-memory state.

## Project Structure

- `src/`
  - `main.zig`: Application bootstrap.
  - `config.zig`: Environment configuration.
  - `server.zig`: HTTP server and request handlers.
  - `queue.zig`: Worker thread queue system.
  - `state.zig`: Bit-packed in-memory storage.
  - `payment_processor.zig`: External payment processor integration.

## How to Run

```bash
docker-compose up --build
```

## Key Optimizations

- **Memory Efficiency**: Bit-packed storage reduces memory footprint by ~75%
- **Lock-free Operations**: Atomic operations for queue management
- **Zero-copy Operations**: Minimal data copying in hot paths
- **Optimized Compilation**: ReleaseFast mode with Zig's advanced optimizations
- **Thread Pool**: Pre-allocated worker threads for consistent performance
docker-compose up

# The API will be available at http://localhost:9999
```

## Dependencies

- httpz: High-performance HTTP server for Zig
- pgzig: PostgreSQL driver for Zig  
- Standard Zig libraries for JSON, networking, etc.

## Performance Optimizations

- Connection pooling for database
- Async worker processing
- Efficient JSON parsing
- Minimal memory allocations
- Alpine Linux for small container size