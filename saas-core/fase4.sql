CREATE TABLE feature_flags (  
    tenant_id UUID REFERENCES tenants(id) PRIMARY KEY,  
    feature_kargo_dropshipping BOOLEAN DEFAULT false,  
    feature_voice_transcription BOOLEAN DEFAULT false  
);  
ALTER TABLE feature_flags ENABLE ROW LEVEL SECURITY;  
CREATE POLICY flags_isolation ON feature_flags   
USING (tenant_id::text = current_setting('app.current_tenant', true));
