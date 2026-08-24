# **MANUAL OPERATIVO DE IMPLEMENTACIÓN**

## **Proyecto: Monolito Modular Multinquilino (SaaS B2B \+ Kargo Dropshipping)**

# **00 — ESTADO ACTUAL**

* **Objetivo:** Desplegar la fase MVP (Minimum Viable Product) de un SaaS B2B conversacional integrado condicionalmente con un módulo de automatización de Dropshipping para Kargo Uruguay.  
* **Alcance MVP:** Despliegue local (Docker Compose) enfocado en estabilizar la arquitectura núcleo (Queue Mode, Base de Datos, Multi-tenancy, WhatsApp) antes de migrar a la nube.  
* **Arquitectura Actual:**  
  * **Motor:** n8n en Queue Mode (1 Main Node, X Worker Nodes).  
  * **Caché y Cola:** Redis / BullMQ.  
  * **Base de datos:** PostgreSQL local (Reemplaza a Supabase, asume RLS nativo).  
  * **Frontend y Auth:** Next.js (Visual/No-code vía Antigravity IDE).  
  * **Pasarela WhatsApp:** Evolution API v2 (Con persistencia en PostgreSQL local).  
  * **Integraciones MVP:** MercadoPago, PayPal, Apify (Scraping), Gmail SMTP (Outbound), Shopify GraphQL 2026-01.  
* **Decisiones tomadas:** Descartado el uso de Supabase para centralizar el esquema relacional puramente en un contenedor de Postgres local; desestimado el scraping nativo en favor de Apify; integración de Kargo vía ingeniería inversa de sus fetch frontend.

# **01 — CÓMO UTILIZAR ESTE DOCUMENTO**

Este manual está diseñado para eliminar la toma de decisiones arquitectónicas durante el desarrollo. Cada tarea está descrita de forma atómica.

* **No saltes pasos.** Las dependencias son estrictas.  
* **Valida cada paso** utilizando el apartado "Validación" antes de cambiar su estado a DONE.  
* Si un comando o flujo falla, dirígete directamente a la sección **Diagnóstico y Solución** de la tarea, o utiliza el árbol de **Troubleshooting** al final del documento.  
* Si te bloqueas o necesitas el código de un paso posterior, indícame tu posición usando el ID (ej. "Estoy en F01-M01-T002").

# **02 — GLOSARIO**

* **Tenant / Inquilino:** Cliente del SaaS (agencia, comercio, usuario de dropshipping).  
* **RLS (Row-Level Security):** Política de PostgreSQL que impide que el Tenant A lea/escriba datos del Tenant B.  
* **Queue Mode:** Configuración de n8n donde un nodo Main recibe peticiones HTTP y Redis distribuye el trabajo a los Workers.  
* **Feature Flag:** Registro en base de datos que activa/desactiva el módulo de Dropshipping para un Tenant.  
* **Idempotencia:** Capacidad del sistema para ignorar peticiones repetidas (evita respuestas dobles en WhatsApp).  
* **JSONL:** Archivo de texto donde cada línea es un JSON válido. Usado para envíos masivos a Shopify.

# **03 — ARQUITECTURA GENERAL**

\[CLIENTE / TENANT\] \--\> \[ NEXT.JS FRONTEND \] \--\> (MercadoPago/PayPal)  
                             | (Emite JWT con tenant\_id)  
                             v  
                     \[ POSTGRESQL (RLS) \] \<--- (Persistencia y Sesiones) \---\> \[ EVOLUTION API v2 \] \<--\> \[ WhatsApp \]  
                             ^  
                             | (Lee Credenciales y Reglas)  
\[ WHATSAPP / WEBHOOKS \] \--\> \[ n8n MAIN NODE \] \--\> \[ REDIS / BULLMQ \]  
                                                 |  
                                            \[ n8n WORKER NODES \]  
                                            /        |         \\  
                                     \[ APIFY \]  \[ SHOPIFY \]  \[ IA/VIDEO \]

# **04 — DECISIONES ARQUITECTÓNICAS (ADRs)**

## **ADR-001 — PostgreSQL Nativo en lugar de Supabase**

* **Problema:** El documento original asume Supabase para el Multi-tenancy, pero el entorno MVP usará Docker puramente local.  
* **Decisión:** Se construirá un esquema RLS nativo en PostgreSQL. El Frontend (Next.js) firmará un JWT. Las consultas a la BD deberán establecer el contexto local mediante SET LOCAL app.current\_tenant \= 'tenant\_id'.  
* **Razón:** Elimina la dependencia de nube para el MVP y permite total control de los contenedores a nivel local, preparando el terreno para una eventual migración a VPS.

## **ADR-002 — Ingesta Masiva a Shopify mediante Staged Uploads**

* **Problema:** Subir miles de productos de Kargo colapsaría los Rate Limits del "Leaky Bucket" de la API GraphQL de Shopify.  
* **Decisión:** Usar stagedUploadsCreate para pedir una URL temporal, subir un archivo .jsonl, y ejecutar bulkOperationRunMutation.  
* **Razón:** Shopify versión 2026-01 permite hasta 5 operaciones de bulk mutation simultáneas y su costo en Rate Limits es de solo 10 puntos (despreciable frente a los límites).

# **05 — ROADMAP (FASES Y ORDEN)**

* **Fase 1:** Infraestructura Base (Docker, Postgres, Redis).  
* **Fase 2:** Autenticación, RLS y Next.js MVP.  
* **Fase 3:** Orquestación y Conectividad (n8n Queue Mode, Evolution API).  
* **Fase 4:** Core Conversacional y Multitenancy Dinámico.  
* **Fase 5:** Módulo Kargo Dropshipping y Shopify.  
* **Fase 6:** Motor de Adquisición (Apify \+ Email Outbound).

# **06 — IMPLEMENTACIÓN PASO A PASO**

## **FASE 1: INFRAESTRUCTURA BASE**

### **STEP ID: F01-M01-T001**

#### **Nombre: Crear red de Docker interna y estructura de carpetas**

* **Objetivo:** Aislar la comunicación entre contenedores.  
* **Contexto:** Evitar el problema del *Hairpin NAT* forzando a los contenedores a comunicarse internamente.  
* **Acción:** Crear los directorios persistentes y la red docker.  
* **Implementación:**  
  mkdir \-p saas-core/{postgres,n8n\_data,redis,evolution\_instances,nextjs}  
  cd saas-core  
  docker network create saas\_network

* **Validación:** docker network ls | grep saas\_network  
* **Criterio DONE:** Directorios creados y red listada en Docker.

### **STEP ID: F01-M01-T002**

#### **Nombre: Desplegar PostgreSQL 16**

* **Objetivo:** Levantar la base de datos central que reemplaza a Supabase.  
* **Prerrequisitos:** F01-M01-T001  
* **Implementación:** Crear docker-compose.yml en el directorio saas-core:  
  version: '3.8'  
  services:  
    postgres:  
      image: postgres:16-alpine  
      container\_name: postgres\_db  
      environment:  
        POSTGRES\_USER: saas\_admin  
        POSTGRES\_PASSWORD: supersecretpassword123  
        POSTGRES\_DB: saas\_db  
      volumes:  
        \- ./postgres:/var/lib/postgresql/data  
      ports:  
        \- "5432:5432"  
      networks:  
        \- saas\_network  
      restart: unless-stopped  
  networks:  
    saas\_network:  
      external: true

  Ejecutar: docker-compose up \-d postgres  
* **Validación:** Conectarse usando DBeaver, pgAdmin o terminal local psql \-h localhost \-U saas\_admin \-d saas\_db.  
* **Criterio DONE:** DB acepta conexiones y persiste datos.

### **STEP ID: F01-M01-T003**

#### **Nombre: Configurar Esquema RLS y Tabla de Tenants**

* **Objetivo:** Sentar las bases del multi-tenancy a nivel fila.  
* **Contexto:** Como no usamos Supabase, debemos inyectar la lógica de seguridad manualmente.  
* **Implementación:** Ejecutar este SQL en la base de datos saas\_db:  
  \-- 1\. Crear extensión para UUIDs  
  CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

  \-- 2\. Tabla Tenants  
  CREATE TABLE tenants (  
      id UUID PRIMARY KEY DEFAULT uuid\_generate\_v4(),  
      name VARCHAR(255) NOT NULL,  
      plan VARCHAR(50) DEFAULT 'free',  
      created\_at TIMESTAMP DEFAULT CURRENT\_TIMESTAMP  
  );

  \-- 3\. Tabla API Keys encriptadas (Vault)  
  CREATE TABLE vault\_credentials (  
      id UUID PRIMARY KEY DEFAULT uuid\_generate\_v4(),  
      tenant\_id UUID REFERENCES tenants(id) ON DELETE CASCADE,  
      service\_name VARCHAR(100) NOT NULL,  
      encrypted\_token TEXT NOT NULL, \-- Cifrado con AES desde Next.js  
      created\_at TIMESTAMP DEFAULT CURRENT\_TIMESTAMP  
  );

  \-- 4\. Activar RLS  
  ALTER TABLE vault\_credentials ENABLE ROW LEVEL SECURITY;

  \-- 5\. Crear la política. Lee la variable de sesión 'app.current\_tenant'  
  CREATE POLICY tenant\_isolation\_policy ON vault\_credentials  
  AS PERMISSIVE FOR ALL  
  TO PUBLIC  
  USING (tenant\_id::text \= current\_setting('app.current\_tenant', true))  
  WITH CHECK (tenant\_id::text \= current\_setting('app.current\_tenant', true));

* **Validación:** Intentar un SELECT en vault\_credentials sin setear la variable. Debe devolver 0 filas. Seteando SET LOCAL app.current\_tenant \= 'uuid-aqui'; debe devolver las filas de ese tenant.  
* **Criterio DONE:** RLS activo e impide lecturas cruzadas.

## **FASE 2: AUTENTICACIÓN Y FRONTEND MVP**

### **STEP ID: F02-M01-T001**

#### **Nombre: Inicializar Next.js Dashboard y Variables de Entorno**

* **Objetivo:** Crear el panel del inquilino compatible con Antigravity IDE.  
* **Prerrequisitos:** Node.js instalado.  
* **Acción:** Dentro de la carpeta nextjs, inicializar el proyecto y crear archivo .env.  
* **Implementación:**  
  npx create-next-app@latest . \--typescript \--tailwind \--eslint \--app  
  npm install jsonwebtoken pg bcrypt mercadopago  
  npm install \-D @types/jsonwebtoken @types/pg @types/bcrypt

  Crear archivo .env en la raíz de nextjs:  
  DATABASE\_URL=postgresql://saas\_admin:supersecretpassword123@localhost:5432/saas\_db  
  JWT\_SECRET=super\_secret\_jwt\_key\_for\_dev  
  MERCADOPAGO\_ACCESS\_TOKEN=tu\_access\_token\_de\_prueba

* **Resultado esperado:** Aplicación Next.js lista para ser importada/abierta en Antigravity IDE.

### **STEP ID: F02-M01-T002**

#### **Nombre: Crear capa de inyección RLS en Next.js (Server Actions)**

* **Objetivo:** Asegurar que cada query a la BD desde Next.js inyecta la identidad del usuario.  
* **Implementación (Código TS \- lib/db.ts):**  
  import { Pool } from 'pg';

  const pool \= new Pool({  
    connectionString: process.env.DATABASE\_URL,  
  });

  export async function queryWithTenant(tenantId: string, queryText: string, params: any\[\]) {  
    const client \= await pool.connect();  
    try {  
      await client.query('BEGIN');  
      await client.query(\`SET LOCAL app.current\_tenant \= '${tenantId}'\`);  
      const res \= await client.query(queryText, params);  
      await client.query('COMMIT');  
      return res;  
    } catch (e) {  
      await client.query('ROLLBACK');  
      throw e;  
    } finally {  
      client.release();  
    }  
  }

* **Validación:** Ejecutar un query de prueba usando queryWithTenant para insertar configuraciones y asegurar que el Constraint RLS lo asigne al tenant correcto.

## **FASE 3: ORQUESTACIÓN Y CONECTIVIDAD**

### **STEP ID: F03-M01-T001**

#### **Nombre: Desplegar Caché Temporal (Redis)**

* **Implementación:** Añadir al docker-compose.yml:  
    redis:  
      image: redis:7-alpine  
      container\_name: redis\_cache  
      networks:  
        \- saas\_network  
      command: redis-server \--appendonly yes  
      volumes:  
        \- ./redis:/data

  docker-compose up \-d redis

### **STEP ID: F03-M01-T002**

#### **Nombre: Desplegar n8n en Queue Mode (Main \+ Worker)**

* **Implementación:** Añadir al docker-compose.yml:  
    n8n-main:  
      image: n8nio/n8n:latest  
      container\_name: n8n\_main  
      environment:  
        \- DB\_TYPE=postgresdb  
        \- DB\_POSTGRESDB\_HOST=postgres  
        \- DB\_POSTGRESDB\_PORT=5432  
        \- DB\_POSTGRESDB\_DATABASE=saas\_db  
        \- DB\_POSTGRESDB\_USER=saas\_admin  
        \- DB\_POSTGRESDB\_PASSWORD=supersecretpassword123  
        \- EXECUTIONS\_MODE=queue  
        \- QUEUE\_BULL\_REDIS\_HOST=redis  
        \- QUEUE\_BULL\_REDIS\_PORT=6379  
        \- N8N\_ENCRYPTION\_KEY=master\_crypto\_seed\_must\_match\_workers\_exactly\_12345  
        \- N8N\_WEBHOOK\_URL=http://localhost:5678 \# Para resolver NAT interno  
      ports:  
        \- "5678:5678"  
      networks:  
        \- saas\_network  
      depends\_on:  
        \- postgres  
        \- redis

    n8n-worker:  
      image: n8nio/n8n:latest  
      container\_name: n8n\_worker\_1  
      command: worker \--concurrency=20  
      environment:  
        \- DB\_TYPE=postgresdb  
        \- DB\_POSTGRESDB\_HOST=postgres  
        \- DB\_POSTGRESDB\_PORT=5432  
        \- DB\_POSTGRESDB\_DATABASE=saas\_db  
        \- DB\_POSTGRESDB\_USER=saas\_admin  
        \- DB\_POSTGRESDB\_PASSWORD=supersecretpassword123  
        \- EXECUTIONS\_MODE=queue  
        \- QUEUE\_BULL\_REDIS\_HOST=redis  
        \- QUEUE\_BULL\_REDIS\_PORT=6379  
        \- N8N\_ENCRYPTION\_KEY=master\_crypto\_seed\_must\_match\_workers\_exactly\_12345  
        \- N8N\_WEBHOOK\_RESPONSE\_RELAY\_SIZE\_MAX=64  
        \- EXECUTIONS\_DATA\_PRUNE=true  
      networks:  
        \- saas\_network  
      depends\_on:  
        \- postgres  
        \- redis

  docker-compose up \-d n8n-main n8n-worker  
* **Validación:** Crear un workflow en http://localhost:5678. Si ejecuta, el Worker funciona.

### **STEP ID: F03-M02-T001**

#### **Nombre: Desplegar Evolution API v2 (PostgreSQL Persistence)**

* **Implementación:** Añadir al docker-compose.yml:  
    evolution-api:  
      image: evoapicloud/evolution-api:v2.3.7  
      container\_name: evolution\_api  
      environment:  
        \- SERVER\_URL=http://localhost:8080  
        \- AUTHENTICATION\_TYPE=apikey  
        \- AUTHENTICATION\_API\_KEY=global\_evolution\_secret\_999  
        \- DATABASE\_ENABLED=true  
        \- DATABASE\_PROVIDER=postgresql  
        \- DATABASE\_CONNECTION\_URI=postgresql://saas\_admin:supersecretpassword123@postgres:5432/saas\_db  
        \- DATABASE\_SAVE\_DATA\_INSTANCE=true  
        \- DATABASE\_SAVE\_DATA\_NEW\_MESSAGE=true  
        \- CACHE\_REDIS\_ENABLED=true  
        \- CACHE\_REDIS\_URI=redis://redis:6379  
        \- CACHE\_REDIS\_PREFIX\_KEY=evo:  
      ports:  
        \- "8080:8080"  
      networks:  
        \- saas\_network  
      depends\_on:  
        \- postgres  
        \- redis

  docker-compose up \-d evolution-api

## **FASE 4: CORE CONVERSACIONAL Y MULTITENANCY DINÁMICO**

### **STEP ID: F04-M01-T001**

#### **Nombre: Crear Tabla de Feature Flags y Lógica de Routing**

* **Implementación SQL en Postgres:**  
  CREATE TABLE feature\_flags (  
      tenant\_id UUID REFERENCES tenants(id) PRIMARY KEY,  
      feature\_kargo\_dropshipping BOOLEAN DEFAULT false,  
      feature\_voice\_transcription BOOLEAN DEFAULT false  
  );  
  ALTER TABLE feature\_flags ENABLE ROW LEVEL SECURITY;  
  CREATE POLICY flags\_isolation ON feature\_flags   
  USING (tenant\_id::text \= current\_setting('app.current\_tenant', true));

### **STEP ID: F04-M01-T002**

#### **Nombre: Crear Workflow Maestro de n8n (Idempotencia y Routing)**

* **Configuración n8n:**  
  1. Nodo **Webhook** (POST, URL /webhook/master-whatsapp).  
  2. Nodo **Redis (Get)**: Llave msg:{{ $json.body.data.message.id }}.  
  3. Nodo **IF (Idempotencia)**: Si la llave existe, finalizar silenciosamente.  
  4. Nodo **Redis (Set)**: Llave msg:{{ $json.body.data.message.id }}, valor 1, TTL 3600\.  
  5. Nodo **Postgres (HTTP Request)**: Consultar estado de Feature Flags.  
  6. Nodo **Switch**: Enrutar a Módulo Kargo o Chatbot normal.

## **FASE 5: MÓDULO KARGO E-COMMERCE Y SHOPIFY**

### **STEP ID: F05-M01-T001**

#### **Nombre: Sub-workflow de Ingesta Kargo (Ingeniería Inversa)**

* **Implementación n8n:**  
  1. Nodo HTTP (POST): Login a Kargo simulado, extraer Token.  
  2. Nodo HTTP (GET): Obtener catálogo (JSON array).  
  3. Nodo Item Lists: Mapear a estructura Shopify.

### **STEP ID: F05-M01-T002**

#### **Nombre: Generador de JSONL y GraphQL Bulk Mutations**

* **Implementación:** Agrupar variables mapeadas en un binario JSONL (Código JS en n8n) y orquestar stagedUploadsCreate y bulkOperationRunMutation mediante nodos HTTP.

## **FASE 6: MOTOR DE ADQUISICIÓN (OUTBOUND MARKETING)**

### **STEP ID: F06-M01-T001**

#### **Nombre: Extracción automatizada de prospectos locales (Apify)**

* **Objetivo:** Usar n8n para gatillar un scraping de Google Maps y traer clientes B2B.  
* **Implementación n8n:**  
  1. Nodo **Schedule Trigger**: Ejecutar Lunes a Viernes a las 09:00 AM.  
  2. Nodo **HTTP Request (POST a Apify API)**: Enviar Payload con término de búsqueda (ej. "Agencias de marketing en Uruguay").  
  3. Nodo **Wait**: Configurado en "Wait for Webhook call" (Para esperar a que Apify termine el raspado sin bloquear el Worker).

### **STEP ID: F06-M01-T002**

#### **Nombre: Flujo de Cold Email (Gmail SMTP)**

* **Objetivo:** Enviar correos fríos estructurados (Newsjacking) a los prospectos extraídos.  
* **Implementación n8n:**  
  1. Nodo **Send Email (SMTP)**: Conectado con credenciales de smtp.gmail.com (App Passwords de Google).  
  2. Configurar Cuerpo: Texto plano sin HTML para evadir filtros de Spam.  
  3. Nodo **Postgres**: Registrar prospecto contactado para evitar duplicados en futuras extracciones.

# **17 — TROUBLESHOOTING GLOBAL (Si Me Trabo)**

### **PROBLEMA: El mensaje de WhatsApp no llega a n8n**

1. **¿Evolution emite el Webhook?** Si apunta a localhost:5678, cámbialo a http://n8n\_main:5678 en la configuración de Evolution para que Docker lo resuelva internamente.

### **PROBLEMA: Rate Limit (HTTP 429\) en Shopify a pesar del Bulk**

1. **Diagnóstico:** ¿Hiciste más de 5 Bulk Operations a la vez? La API 2026-01 de Shopify limita a 5 operaciones concurrentes.

# **21 — ESTADO ACTUAL DEL PROYECTO**

* **NOT\_STARTED:** Todas las fases.  
* **IN\_PROGRESS:** Fase 1 (Listos para ejecutar comandos Docker).  
* **NEXT RECOMMENDED STEP:** Ejecutar Paso F01-M01-T001 (Crear red y carpetas) y confirmar resultado.

**COPILOTO ACTIVADO:** Cuando estés listo para comenzar, abre tu terminal y dime: **"Voy a ejecutar F01-M01-T001"**.