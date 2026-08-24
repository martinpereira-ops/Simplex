-- 1. Crear extensión para UUIDs
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 2. Tabla Tenants
CREATE TABLE tenants (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    plan VARCHAR(50) DEFAULT 'free',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 3. Tabla API Keys encriptadas (Vault)
CREATE TABLE vault_credentials (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
    service_name VARCHAR(100) NOT NULL,
    encrypted_token TEXT NOT NULL, -- Cifrado con AES desde Next.js
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 4. Activar RLS
ALTER TABLE vault_credentials ENABLE ROW LEVEL SECURITY;

-- 5. Crear la política. Lee la variable de sesión 'app.current_tenant'
CREATE POLICY tenant_isolation_policy ON vault_credentials
AS PERMISSIVE FOR ALL
TO PUBLIC
USING (tenant_id::text = current_setting('app.current_tenant', true))
WITH CHECK (tenant_id::text = current_setting('app.current_tenant', true));
