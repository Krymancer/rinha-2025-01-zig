# Queue-Based Payment Processing in Zig

## Overview

This Zig implementation features a sophisticated async payment processing system with queue-based processing and background health monitoring, inspired by high-performance Rust architectures.

## Architecture Components

### **PaymentQueue** (`src/payment_queue.zig`)
- Thread-safe queue implementation using mutexes and condition variables
- Support for blocking `waitAndPop()` operations
- Atomic counters for queue size tracking
- Graceful shutdown capability

### **AsyncPaymentService** (`src/async_payment_service.zig`)
- Queue-based payment processing with background workers
- Continuous health monitoring in separate threads
- Circuit breaker pattern with response time monitoring
- Failed payment retry mechanism
- Atomic health status tracking

### **Background Workers**
- **Payment Workers**: Process payments from the main queue (2 workers)
- **Health Monitor**: Continuously checks processor health every 1 second
- **Failed Queue Retry**: Requeues failed payments when processors recover

## Key Features

### **🚀 Non-Blocking API**
```bash
curl -X POST http://localhost:8080/payments \
  -H "Content-Type: application/json" \
  -d '{"correlationId": "550e8400-e29b-41d4-a716-446655440000", "amount": 100.50}'

# Returns immediately with 202 Accepted
{"message": "Payment queued for processing"}
```

### **⚡ Circuit Breaker**
Automatically switches processors based on performance:
- 200ms response time threshold
- Real-time health monitoring
- Automatic failover and recovery

### **🔄 Failed Payment Recovery**
- Failed payments automatically queued for retry
- Retry when processors recover
- No payment loss during outages

## Usage

### **Build & Run**
```bash
zig build
./zig-out/bin/backend.exe
```

### **Health Monitoring**
```bash
curl http://localhost:8080/health
```

Response:
```json
{
  "status": "healthy",
  "processors": {
    "default": { "failing": false },
    "fallback": { "failing": false }
  },
  "queues": {
    "pending": 0,
    "failed": 0
  }
}
```

### **Payment Summary**
```bash
curl http://localhost:8080/payments-summary
```

Response:
```json
{
  "default": {
    "totalRequests": 150,
    "totalAmount": 15750.50
  },
  "fallback": {
    "totalRequests": 25,
    "totalAmount": 2500.00
  }
}
```

## Configuration

Optimized settings in `src/config.zig`:
- **Health check interval**: 1 second (frequent monitoring)
- **Timeout**: 2 seconds (fast failure detection)
- **Payment processor URLs**: Configurable endpoints

## Performance Benefits

### **High Throughput**
- Non-blocking API responses
- Concurrent background processing
- Efficient worker thread pool

### **Resilience**
- Circuit breaker prevents cascade failures
- Automatic retry of failed payments
- Graceful degradation during outages

### **Observability**
- Real-time queue monitoring
- Health status tracking
- Response time monitoring

## Architecture Flow

```
HTTP Request → Validate → Queue → 202 Response
                           ↓
                   Background Workers
                           ↓
              Choose Processor (Circuit Breaker)
                           ↓
                   HTTP Call to Processor
                           ↓
                   Update Statistics & Health
                           ↓
               Failed Queue (if needed for retry)
```

## Why This Architecture?

1. **No Blocking**: HTTP responses are immediate (202 Accepted)
2. **Better Resilience**: Failed payments are automatically retried
3. **Circuit Breaker**: Prevents cascade failures from slow processors
4. **Real-time Monitoring**: Continuous health checks and observability
5. **Memory Safety**: Zig's compile-time guarantees prevent runtime errors
6. **Performance**: Lower memory footprint than equivalent solutions

This implementation should solve payment processor reliability issues by eliminating blocking retries, providing real-time health monitoring, and implementing circuit breaker logic for automatic failover.
