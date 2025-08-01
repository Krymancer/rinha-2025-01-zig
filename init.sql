-- Database schema for Rinha de Backend 2025 payment system

CREATE TABLE IF NOT EXISTS payments (
    id SERIAL PRIMARY KEY,
    correlation_id UUID NOT NULL UNIQUE,
    amount DECIMAL(10,2) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    processor VARCHAR(50),
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_payments_correlation_id ON payments(correlation_id);
CREATE INDEX IF NOT EXISTS idx_payments_status ON payments(status);
CREATE INDEX IF NOT EXISTS idx_payments_created_at ON payments(created_at);

-- Sample data
-- INSERT INTO payments (correlation_id, amount, status) 
-- VALUES ('550e8400-e29b-41d4-a716-446655440000', 100.00, 'pending');
