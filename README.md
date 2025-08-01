# Rinha de Backend 2025 - Zig Implementation

This is my implementation for the Rinha de Backend 2025 challenge using Zig programming language.

## Technologies Used

- **Language**: Zig 0.13.0
- **HTTP Server**: httpz (Zig HTTP library)
- **Database**: PostgreSQL with pgzig driver
- **Queue**: In-memory queue (Redis-like interface) 
- **Load Balancer**: HAProxy
- **Containerization**: Docker & Docker Compose

## Architecture

The solution follows a distributed architecture with:

- **2 API instances** running the Zig backend
- **HAProxy** as load balancer distributing requests between instances
- **PostgreSQL** for persistent storage
- **Redis** for caching and queue management
- **Background workers** for async payment processing

## API Endpoints

- `POST /payments` - Submit payment for processing
- `GET /payments-summary` - Get payment processing summary
- `GET /health` - Health check endpoint

## How it Works

1. **Payment Submission**: Payments are received via POST /payments, validated, stored in PostgreSQL, and queued for processing
2. **Background Processing**: Worker threads dequeue payments and attempt to process them via payment processors
3. **Processor Selection**: Default processor is tried first (lower fees), fallback processor as backup
4. **Health Monitoring**: Periodic health checks determine which processors are available
5. **Summary Reports**: GET /payments-summary provides aggregated data for auditing

## Resource Limits

The docker-compose.yml is configured to respect the challenge limits:
- **Total CPU**: 1.5 cores
- **Total Memory**: 350MB

## Local Development

```bash
# Build the project
zig build

# Run with Docker Compose
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