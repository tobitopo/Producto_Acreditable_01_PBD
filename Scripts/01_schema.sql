-- PROYECTO: Efest — Gestor de Contrasenas con SQL Server
-- REPOSITORIO: Producto_Acreditable_01_PBD
-- ENTREGABLE: sql/01_schema.sql


-- -------------------------------------------
-- 1. CREACION DE LA BASE DE DATOS
-- ----------------------------------------------

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'EfestDB')
BEGIN
    CREATE DATABASE EfestDB
    COLLATE Modern_Spanish_100_CI_AI_SC_UTF8;
END
GO

USE EfestDB;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- -------------------------------------------------
-- 2. LIMPIEZA DE TABLAS PREVIAS
-- --------------------------------------------------
IF OBJECT_ID(N'dbo.AuditLog', N'U') IS NOT NULL DROP TABLE dbo.AuditLog;
IF OBJECT_ID(N'dbo.TotpConfig', N'U') IS NOT NULL DROP TABLE dbo.TotpConfig;
IF OBJECT_ID(N'dbo.SecureNote', N'U') IS NOT NULL DROP TABLE dbo.SecureNote;

IF OBJECT_ID(N'dbo.CredentialTag', N'U') IS NOT NULL DROP TABLE dbo.CredentialTag;
IF OBJECT_ID(N'dbo.CredentialHistory', N'U') IS NOT NULL DROP TABLE dbo.CredentialHistory;
IF OBJECT_ID(N'dbo.Credential', N'U') IS NOT NULL DROP TABLE dbo.Credential;
IF OBJECT_ID(N'dbo.Tag', N'U') IS NOT NULL DROP TABLE dbo.Tag;
IF OBJECT_ID(N'dbo.Category', N'U') IS NOT NULL DROP TABLE dbo.Category;
IF OBJECT_ID(N'dbo.Vault', N'U') IS NOT NULL DROP TABLE dbo.Vault;
IF OBJECT_ID(N'dbo.VaultUser', N'U') IS NOT NULL DROP TABLE dbo.VaultUser;
GO

-- ----------------------------------------------------------------------------
-- 3. DEFINICION DE TABLAS FISICAS (3FN)
-- ----------------------------------------------------------------------------

-- TABLA 1: VaultUser (Identifica al usuario / titular del sistema)
CREATE TABLE dbo.VaultUser (
    user_id     UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_VaultUser_user_id DEFAULT NEWID(),
    login_name  NVARCHAR(128)    NOT NULL,

    CONSTRAINT PK_VaultUser PRIMARY KEY CLUSTERED (user_id),
    CONSTRAINT UQ_VaultUser_login_name UNIQUE NONCLUSTERED (login_name),
    CONSTRAINT CK_VaultUser_login_name_NotEmpty CHECK (LEN(LTRIM(RTRIM(login_name))) > 0)
);
GO

-- TABLA 2: Vault 
-- (Boveda que agrupa secretos y conserva parametros Argon2id)
CREATE TABLE dbo.Vault (
    vault_id         UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Vault_vault_id DEFAULT NEWID(),
    owner_id         UNIQUEIDENTIFIER NOT NULL,
    salt             VARBINARY(16)    NOT NULL,
    ops_limit        INT              NOT NULL,
    mem_limit_kib    INT              NOT NULL,
    check_ciphertext VARBINARY(MAX)   NOT NULL,
    check_nonce      VARBINARY(24)    NOT NULL,

    CONSTRAINT PK_Vault PRIMARY KEY CLUSTERED (vault_id),
    CONSTRAINT FK_Vault_VaultUser FOREIGN KEY (owner_id) 
        REFERENCES dbo.VaultUser (user_id) 
        ON DELETE CASCADE,
    CONSTRAINT CK_Vault_salt_length CHECK (DATALENGTH(salt) = 16),
    CONSTRAINT CK_Vault_check_nonce_length CHECK (DATALENGTH(check_nonce) = 24),
    CONSTRAINT CK_Vault_ops_limit CHECK (ops_limit >= 1),
    CONSTRAINT CK_Vault_mem_limit_kib CHECK (mem_limit_kib >= 1024)
);
GO

-- TABLA 3: Category (Categorias organizativas dentro de una boveda)
CREATE TABLE dbo.Category (
    category_id UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Category_category_id DEFAULT NEWID(),
    vault_id    UNIQUEIDENTIFIER NOT NULL,
    name        NVARCHAR(100)    NOT NULL,

    CONSTRAINT PK_Category PRIMARY KEY CLUSTERED (category_id),
    CONSTRAINT FK_Category_Vault FOREIGN KEY (vault_id) 
        REFERENCES dbo.Vault (vault_id) 
        ON DELETE CASCADE,
    CONSTRAINT UQ_Category_vault_name UNIQUE NONCLUSTERED (vault_id, name),
    CONSTRAINT CK_Category_name_NotEmpty CHECK (LEN(LTRIM(RTRIM(name))) > 0)
);
GO

-- TABLA 4: Tag (Etiquetas reutilizables por boveda para busqueda transversal)
CREATE TABLE dbo.Tag (
    tag_id   UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Tag_tag_id DEFAULT NEWID(),
    vault_id UNIQUEIDENTIFIER NOT NULL,
    name     NVARCHAR(100)    NOT NULL,

    CONSTRAINT PK_Tag PRIMARY KEY CLUSTERED (tag_id),
    CONSTRAINT FK_Tag_Vault FOREIGN KEY (vault_id) 
        REFERENCES dbo.Vault (vault_id) 
        ON DELETE CASCADE,
    CONSTRAINT UQ_Tag_vault_name UNIQUE NONCLUSTERED (vault_id, name),
    CONSTRAINT CK_Tag_name_NotEmpty CHECK (LEN(LTRIM(RTRIM(name))) > 0)
);
GO

-- TABLA 5: Credential (Cuentas guardadas: metadatos indexables + secreto cifrado)
CREATE TABLE dbo.Credential (
    credential_id       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Credential_credential_id DEFAULT NEWID(),
    vault_id            UNIQUEIDENTIFIER NOT NULL,
    category_id         UNIQUEIDENTIFIER NULL,
    title               NVARCHAR(200)    NOT NULL,
    username            NVARCHAR(256)    NULL,
    url                 NVARCHAR(2048)   NULL,
    password_ciphertext VARBINARY(MAX)   NOT NULL,
    nonce               VARBINARY(24)    NOT NULL,

    CONSTRAINT PK_Credential PRIMARY KEY CLUSTERED (credential_id),
    CONSTRAINT FK_Credential_Vault FOREIGN KEY (vault_id) 
        REFERENCES dbo.Vault (vault_id) 
        ON DELETE NO ACTION, -- Evita ciclo/rutas multiples en cascada desde Vault
    CONSTRAINT FK_Credential_Category FOREIGN KEY (category_id) 
        REFERENCES dbo.Category (category_id) 
        ON DELETE SET NULL,
    CONSTRAINT CK_Credential_title_NotEmpty CHECK (LEN(LTRIM(RTRIM(title))) > 0),
    CONSTRAINT CK_Credential_nonce_length CHECK (DATALENGTH(nonce) = 24)
);
GO

-- TABLA 6: CredentialTag (Relacion N:M entre Credenciales y Etiquetas)
CREATE TABLE dbo.CredentialTag (
    credential_id UNIQUEIDENTIFIER NOT NULL,
    tag_id        UNIQUEIDENTIFIER NOT NULL,

    CONSTRAINT PK_CredentialTag PRIMARY KEY CLUSTERED (credential_id, tag_id),
    CONSTRAINT FK_CredentialTag_Credential FOREIGN KEY (credential_id) 
        REFERENCES dbo.Credential (credential_id) 
        ON DELETE CASCADE,
    CONSTRAINT FK_CredentialTag_Tag FOREIGN KEY (tag_id) 
        REFERENCES dbo.Tag (tag_id) 
        ON DELETE NO ACTION -- Evita ciclos de cascada con SQL Server
);
GO

-- TABLA 7: CredentialHistory (Historial inmutable de contrasenas anteriores)
CREATE TABLE dbo.CredentialHistory (
    history_id          BIGINT IDENTITY(1,1) NOT NULL,
    credential_id       UNIQUEIDENTIFIER     NOT NULL,
    replaced_at         DATETIME2(3)         NOT NULL CONSTRAINT DF_CredentialHistory_replaced_at DEFAULT SYSUTCDATETIME(),
    password_ciphertext VARBINARY(MAX)       NOT NULL,
    nonce               VARBINARY(24)        NOT NULL,

    CONSTRAINT PK_CredentialHistory PRIMARY KEY CLUSTERED (history_id),
    CONSTRAINT FK_CredentialHistory_Credential FOREIGN KEY (credential_id) 
        REFERENCES dbo.Credential (credential_id) 
        ON DELETE CASCADE,
    CONSTRAINT CK_CredentialHistory_nonce_length CHECK (DATALENGTH(nonce) = 24)
);
GO

-- TABLA 8: SecureNote (Notas privadas cifradas por boveda)
CREATE TABLE dbo.SecureNote (
    note_id         UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_SecureNote_note_id DEFAULT NEWID(),
    vault_id        UNIQUEIDENTIFIER NOT NULL,
    title           NVARCHAR(200)    NOT NULL,
    body_ciphertext VARBINARY(MAX)   NOT NULL,
    nonce           VARBINARY(24)    NOT NULL,

    CONSTRAINT PK_SecureNote PRIMARY KEY CLUSTERED (note_id),
    CONSTRAINT FK_SecureNote_Vault FOREIGN KEY (vault_id) 
        REFERENCES dbo.Vault (vault_id) 
        ON DELETE CASCADE,
    CONSTRAINT CK_SecureNote_title_NotEmpty CHECK (LEN(LTRIM(RTRIM(title))) > 0),
    CONSTRAINT CK_SecureNote_nonce_length CHECK (DATALENGTH(nonce) = 24)
);
GO

-- TABLA 9: TotpConfig (Configuracion 1:0..1 de segundo factor para credenciales)
CREATE TABLE dbo.TotpConfig (
    credential_id   UNIQUEIDENTIFIER NOT NULL,
    seed_ciphertext VARBINARY(MAX)   NOT NULL,
    nonce           VARBINARY(24)    NOT NULL,
    algorithm       NVARCHAR(16)     NOT NULL CONSTRAINT DF_TotpConfig_algorithm DEFAULT N'SHA1',
    digits          TINYINT          NOT NULL CONSTRAINT DF_TotpConfig_digits DEFAULT 6,
    period_seconds  SMALLINT         NOT NULL CONSTRAINT DF_TotpConfig_period DEFAULT 30,

    CONSTRAINT PK_TotpConfig PRIMARY KEY CLUSTERED (credential_id),
    CONSTRAINT FK_TotpConfig_Credential FOREIGN KEY (credential_id) 
        REFERENCES dbo.Credential (credential_id) 
        ON DELETE CASCADE,
    CONSTRAINT CK_TotpConfig_algorithm CHECK (algorithm IN (N'SHA1', N'SHA256', N'SHA512')),
    CONSTRAINT CK_TotpConfig_digits CHECK (digits IN (6, 7, 8)),
    CONSTRAINT CK_TotpConfig_period_seconds CHECK (period_seconds > 0),
    CONSTRAINT CK_TotpConfig_nonce_length CHECK (DATALENGTH(nonce) = 24)
);
GO

-- TABLA 10: AuditLog (Registro inmutable de eventos y accesos de seguridad)
-- Regla: Excluye borrado en cascada para garantizar trazabilidad forense
CREATE TABLE dbo.AuditLog (
    event_id    BIGINT IDENTITY(1,1) NOT NULL,
    actor_id    UNIQUEIDENTIFIER     NOT NULL,
    vault_id    UNIQUEIDENTIFIER     NULL,
    occurred_at DATETIME2(3)         NOT NULL CONSTRAINT DF_AuditLog_occurred_at DEFAULT SYSUTCDATETIME(),
    action      NVARCHAR(16)         NOT NULL,
    target_type NVARCHAR(32)         NOT NULL,
    target_id   UNIQUEIDENTIFIER     NOT NULL,

    CONSTRAINT PK_AuditLog PRIMARY KEY CLUSTERED (event_id),
    CONSTRAINT FK_AuditLog_VaultUser FOREIGN KEY (actor_id) 
        REFERENCES dbo.VaultUser (user_id) 
        ON DELETE NO ACTION, -- Exclusion estricta de cascada
    CONSTRAINT FK_AuditLog_Vault FOREIGN KEY (vault_id) 
        REFERENCES dbo.Vault (vault_id) 
        ON DELETE NO ACTION, -- Exclusion estricta de cascada
    CONSTRAINT CK_AuditLog_action CHECK (action IN (N'login', N'unlock', N'create', N'update', N'reveal', N'export')),
    CONSTRAINT CK_AuditLog_target_type CHECK (target_type IN (N'VaultUser', N'Vault', N'Credential', N'SecureNote', N'Category', N'Tag', N'TotpConfig'))
);
GO

-- ------------------------------------------------------------------------
-- 4. INDICES NO CLUSTERIZADOS ESTRATEGICOS (OPTIMIZACION DE CONSULTAS Y JOINS)
-- -----------------------------------------------------------------------
GO

-- Busqueda y listado de credenciales por boveda y titulo (Soporte RF02, RF07)
CREATE NONCLUSTERED INDEX IX_Credential_vault_id_title 
ON dbo.Credential (vault_id, title)
INCLUDE (category_id, username, url);
GO

-- Busqueda de credenciales por categoria (Soporte RF03, RF07)
CREATE NONCLUSTERED INDEX IX_Credential_category_id 
ON dbo.Credential (category_id)
WHERE category_id IS NOT NULL;
GO

-- Busqueda inversa en relacion N:M (Soporte RF03, RF07)
CREATE NONCLUSTERED INDEX IX_CredentialTag_tag_id 
ON dbo.CredentialTag (tag_id)
INCLUDE (credential_id);
GO

-- Historial por credencial ordenado cronologicamente (Soporte RF04)
CREATE NONCLUSTERED INDEX IX_CredentialHistory_credential_id_replaced_at 
ON dbo.CredentialHistory (credential_id, replaced_at DESC);
GO

-- Listado de notas seguras por boveda (Soporte RF06)
CREATE NONCLUSTERED INDEX IX_SecureNote_vault_id_title 
ON dbo.SecureNote (vault_id, title);
GO

-- Auditoria por actor y fecha (Soporte RF05)
CREATE NONCLUSTERED INDEX IX_AuditLog_actor_id_occurred_at 
ON dbo.AuditLog (actor_id, occurred_at DESC);
GO

-- Auditoria por boveda y fecha (Soporte RF05)
CREATE NONCLUSTERED INDEX IX_AuditLog_vault_id_occurred_at 
ON dbo.AuditLog (vault_id, occurred_at DESC)
WHERE vault_id IS NOT NULL;
GO

-- Auditoria por objeto objetivo (Trazabilidad forense directa)
CREATE NONCLUSTERED INDEX IX_AuditLog_target_id_target_type 
ON dbo.AuditLog (target_id, target_type);
GO

-- ---------------------------------------------------------------------------
-- 5. DOCUMENTACION DE METADATOS MEDIANTE EXTENDED PROPERTIES 
-- ---------------------------------------------------------------------------
GO

-- Extended properties para VaultUser
EXEC sys.sp_addextendedproperty 
    @name = N'MS_Description', 
    @value = N'Identifica a cada usuario de Efest. Un usuario puede ser titular de varias bovedas.', 
    @level0type = N'SCHEMA', @level0name = N'dbo', 
    @level1type = N'TABLE',  @level1name = N'VaultUser';
GO

EXEC sys.sp_addextendedproperty 
    @name = N'MS_Description', 
    @value = N'Identidad estable. Clave primaria del usuario de Efest.', 
    @level0type = N'SCHEMA', @level0name = N'dbo', 
    @level1type = N'TABLE',  @level1name = N'VaultUser',
    @level2type = N'COLUMN', @level2name = N'user_id';
GO

EXEC sys.sp_addextendedproperty 
    @name = N'MS_Description', 
    @value = N'Acceso a Efest. Nombre unico con el que el usuario inicia sesion.', 
    @level0type = N'SCHEMA', @level0name = N'dbo', 
    @level1type = N'TABLE',  @level1name = N'VaultUser',
    @level2type = N'COLUMN', @level2name = N'login_name';
GO

-- Extended properties para Vault
EXEC sys.sp_addextendedproperty 
    @name = N'MS_Description', 
    @value = N'Agrupa las credenciales y notas de un titular y guarda los parametros para desbloquear la boveda.', 
    @level0type = N'SCHEMA', @level0name = N'dbo', 
    @level1type = N'TABLE',  @level1name = N'Vault';
GO

EXEC sys.sp_addextendedproperty 
    @name = N'MS_Description', 
    @value = N'Derivacion de clave. Valor aleatorio de 16 bytes que se combina con la contrasena maestra para derivar la clave con Argon2id.', 
    @level0type = N'SCHEMA', @level0name = N'dbo', 
    @level1type = N'TABLE',  @level1name = N'Vault',
    @level2type = N'COLUMN', @level2name = N'salt';
GO

EXEC sys.sp_addextendedproperty 
    @name = N'MS_Description', 
    @value = N'Verificacion de la clave. Marca cifrada que permite al cliente comprobar que la clave es correcta.', 
    @level0type = N'SCHEMA', @level0name = N'dbo', 
    @level1type = N'TABLE',  @level1name = N'Vault',
    @level2type = N'COLUMN', @level2name = N'check_ciphertext';
GO

-- Extended properties para Credential
EXEC sys.sp_addextendedproperty 
    @name = N'MS_Description', 
    @value = N'Representa una cuenta guardada, con sus datos de busqueda y su contrasena vigente cifrada.', 
    @level0type = N'SCHEMA', @level0name = N'dbo', 
    @level1type = N'TABLE',  @level1name = N'Credential';
GO

EXEC sys.sp_addextendedproperty 
    @name = N'MS_Description', 
    @value = N'Secreto cifrado. Contrasena vigente del servicio, cifrada por el cliente antes de guardarla.', 
    @level0type = N'SCHEMA', @level0name = N'dbo', 
    @level1type = N'TABLE',  @level1name = N'Credential',
    @level2type = N'COLUMN', @level2name = N'password_ciphertext';
GO

-- Extended properties para AuditLog
EXEC sys.sp_addextendedproperty 
    @name = N'MS_Description', 
    @value = N'Registra quien realizo una accion, cuando ocurrio y sobre que objeto. La aplicacion solo puede agregar eventos.', 
    @level0type = N'SCHEMA', @level0name = N'dbo', 
    @level1type = N'TABLE',  @level1name = N'AuditLog';
GO