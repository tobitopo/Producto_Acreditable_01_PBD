-- Datos ficticios para EfestDB. Ejecutar después de 01_schema.sql.
-- El cifrado de estos ejemplos se simula en SQL Server con una frase de prueba.
USE EfestDB;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @user_id UNIQUEIDENTIFIER = '8f5a84f1-14e6-45b6-ad54-15a355ab0001';
DECLARE @vault_id UNIQUEIDENTIFIER = '8f5a84f1-14e6-45b6-ad54-15a355ab0002';
DECLARE @work_category_id UNIQUEIDENTIFIER = '8f5a84f1-14e6-45b6-ad54-15a355ab0003';
DECLARE @personal_category_id UNIQUEIDENTIFIER = '8f5a84f1-14e6-45b6-ad54-15a355ab0004';
DECLARE @frequent_tag_id UNIQUEIDENTIFIER = '8f5a84f1-14e6-45b6-ad54-15a355ab0005';
DECLARE @important_tag_id UNIQUEIDENTIFIER = '8f5a84f1-14e6-45b6-ad54-15a355ab0006';
DECLARE @mail_id UNIQUEIDENTIFIER = '8f5a84f1-14e6-45b6-ad54-15a355ab0007';
DECLARE @library_id UNIQUEIDENTIFIER = '8f5a84f1-14e6-45b6-ad54-15a355ab0008';
DECLARE @forum_id UNIQUEIDENTIFIER = '8f5a84f1-14e6-45b6-ad54-15a355ab0009';

DECLARE @demo_passphrase NVARCHAR(128) = N'Efest-frase-ficticia-de-demostración';
DECLARE @vault_marker VARBINARY(32) = HASHBYTES('SHA2_256', N'Efest:verificación de bóveda de prueba');
DECLARE @mail_nonce VARBINARY(24) = CRYPT_GEN_RANDOM(24);
DECLARE @library_nonce VARBINARY(24) = CRYPT_GEN_RANDOM(24);
DECLARE @forum_nonce VARBINARY(24) = CRYPT_GEN_RANDOM(24);

BEGIN TRY
    BEGIN TRANSACTION;

    -- El bloqueo sobre el titular serializa ejecuciones simultáneas de esta carga.
    IF NOT EXISTS (
        SELECT 1 FROM dbo.VaultUser WITH (UPDLOCK, HOLDLOCK) WHERE user_id = @user_id
    )
        INSERT INTO dbo.VaultUser (user_id, login_name)
        VALUES (@user_id, N'efest.demo@example.com');

    IF NOT EXISTS (SELECT 1 FROM dbo.Vault WHERE vault_id = @vault_id)
        INSERT INTO dbo.Vault (vault_id, owner_id, salt, ops_limit, mem_limit_kib, check_ciphertext, check_nonce)
        VALUES (
            @vault_id, @user_id, CRYPT_GEN_RANDOM(16), 3, 65536,
            ENCRYPTBYPASSPHRASE(@demo_passphrase, @vault_marker), CRYPT_GEN_RANDOM(24)
        );

    INSERT INTO dbo.Category (category_id, vault_id, name)
    SELECT demo.category_id, @vault_id, demo.name
    FROM (VALUES
        (@work_category_id, N'Trabajo'),
        (@personal_category_id, N'Personal')
    ) AS demo (category_id, name)
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.Category AS existing WHERE existing.category_id = demo.category_id
    );

    INSERT INTO dbo.Tag (tag_id, vault_id, name)
    SELECT demo.tag_id, @vault_id, demo.name
    FROM (VALUES
        (@frequent_tag_id, N'Frecuente'),
        (@important_tag_id, N'Importante')
    ) AS demo (tag_id, name)
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.Tag AS existing WHERE existing.tag_id = demo.tag_id
    );

    INSERT INTO dbo.Credential (credential_id, vault_id, category_id, title, username, url, password_ciphertext, nonce)
    SELECT demo.credential_id, @vault_id, demo.category_id, demo.title, demo.username, demo.url,
           ENCRYPTBYPASSPHRASE(@demo_passphrase, demo.demo_password), demo.nonce
    FROM (VALUES
        (@mail_id, @work_category_id, N'Correo de trabajo', N'efest.demo@example.com',
         N'https://mail.example.com', N'Correo-ficticio-01', @mail_nonce),
        (@library_id, @personal_category_id, N'Biblioteca virtual', N'lector-demo',
         N'https://library.example.com', N'Biblioteca-ficticia-02', @library_nonce),
        (@forum_id, NULL, N'Foro de demostración', N'visitante-demo',
         N'https://forum.example.com', N'Foro-ficticio-03', @forum_nonce)
    ) AS demo (credential_id, category_id, title, username, url, demo_password, nonce)
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.Credential AS existing WHERE existing.credential_id = demo.credential_id
    );

    INSERT INTO dbo.CredentialTag (credential_id, tag_id)
    SELECT demo.credential_id, demo.tag_id
    FROM (VALUES
        (@mail_id, @frequent_tag_id),
        (@mail_id, @important_tag_id),
        (@library_id, @frequent_tag_id)
    ) AS demo (credential_id, tag_id)
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.CredentialTag AS existing
        WHERE existing.credential_id = demo.credential_id AND existing.tag_id = demo.tag_id
    );

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
