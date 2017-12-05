

-- note, warn that we're enabling xp_cmdshell... 
--		point to a link where we outline that it's NOT a problem. 
--			and... the link... needs to be the link that both backups and restore scripts point to... 


-- enable advanced options as necessary. (and save a 'bit value' to revert as needed)... 
-- then enable xp_cmdshell and output an ERROR... so'z people can see a 'warning' that xp_cmdshell was enabled. 




IF EXISTS (SELECT NULL FROM sys.configurations WHERE [name] = N'xp_cmdshell' AND value_in_use = 0) BEGIN;

	PRINT 'NOTE: Enabling xp_cmdshell for use by SysAdmin role-members only.';

	IF EXISTS (SELECT NULL FROM sys.configurations WHERE [name] = 'show advanced options' AND value_in_use = 0) BEGIN

		EXEC sp_configure 'show advanced options', 1;
			
		RECONFIGURE;

		EXEC sp_configure 'xp_cmdshell', 1;
		
		RECONFIGURE;


		-- switch BACK to not-showing advanced options:
		EXEC sp_configure 'show advanced options', 1;
			
		RECONFIGURE;

	  END;
	ELSE BEGIN

		EXEC sp_configure 'xp_cmdshell', 1;
		
		RECONFIGURE;
	END;
END;
GO


USE [master];
GO

IF NOT EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = 'admindb') BEGIN
	CREATE DATABASE [admindb];  -- TODO: look at potentially defining growth size details - based upon what is going on with model/etc. 

	ALTER AUTHORIZATION ON DATABASE::[admindb] TO sa;

	ALTER DATABASE [admindb] SET RECOVERY SIMPLE;  -- i.e., treat like master/etc. 
END;
GO

USE [admindb];
GO

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- create and populate version history info:
IF OBJECT_ID('version_history', 'U') IS NULL BEGIN

	CREATE TABLE dbo.version_history (
		version_id int IDENTITY(1,1) NOT NULL, 
		version_number varchar(20) NOT NULL, 
		[description] nvarchar(200) NULL, 
		deployed datetime NOT NULL CONSTRAINT DF_version_info_deployed DEFAULT GETDATE(), 
		CONSTRAINT PK_version_info PRIMARY KEY CLUSTERED (version_id)
	);

	EXEC sys.sp_addextendedproperty
		@name = 'S4',
		@value = 'TRUE',
		@level0type = 'Schema',
		@level0name = 'dbo',
		@level1type = 'Table',
		@level1name = 'version_history';
END;

DECLARE @CurrentVersion varchar(20) = N'4.0.1.16756';

-- Add current version info:
IF NOT EXISTS (SELECT NULL FROM dbo.version_history WHERE [version_number] = @CurrentVersion) BEGIN
	INSERT INTO dbo.version_history (version_number, [description], deployed)
	VALUES (@CurrentVersion, 'Deployed via Upgrade Script.', GETDATE());
END;

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Setup and Copy info from backup and restore logs... 
IF OBJECT_ID('dbo.backup_log', 'U') IS NULL BEGIN

	CREATE TABLE dbo.backup_log  (
		backup_id int IDENTITY(1,1) NOT NULL,
		execution_id uniqueidentifier NOT NULL,
		backup_date date NOT NULL CONSTRAINT DF_backup_log_log_date DEFAULT (GETDATE()),
		[database] sysname NOT NULL, 
		backup_type sysname NOT NULL,
		backup_path nvarchar(1000) NOT NULL, 
		copy_path nvarchar(1000) NULL, 
		backup_start datetime NOT NULL, 
		backup_end datetime NULL, 
		backup_succeeded bit NOT NULL CONSTRAINT DF_backup_log_backup_succeeded DEFAULT (0), 
		verification_start datetime NULL, 
		verification_end datetime NULL, 
		verification_succeeded bit NULL, 
		copy_succeeded bit NULL, 
		copy_seconds int NULL, 
		failed_copy_attempts int NULL, 
		copy_details nvarchar(MAX) NULL,
		error_details nvarchar(MAX) NULL, 
		CONSTRAINT PK_backup_log PRIMARY KEY CLUSTERED (backup_id)
	);	

END;

IF OBJECT_ID('dbo.restore_log', 'U') IS NULL BEGIN

	CREATE TABLE dbo.restore_log  (
		restore_test_id int IDENTITY(1,1) NOT NULL,
		execution_id uniqueidentifier NOT NULL,
		test_date date NOT NULL CONSTRAINT DF_restore_log_test_date DEFAULT (GETDATE()),
		[database] sysname NOT NULL, 
		restored_as sysname NOT NULL, 
		restore_start datetime NOT NULL, 
		restore_end datetime NULL, 
		restore_succeeded bit NOT NULL CONSTRAINT DF_restore_log_restore_succeeded DEFAULT (0), 
		consistency_start datetime NULL, 
		consistency_end datetime NULL, 
		consistency_succeeded bit NULL, 
		dropped varchar(20) NOT NULL CONSTRAINT DF_restore_log_dropped DEFAULT 'NOT-DROPPED',   -- Options: NOT-DROPPED, ERROR, ATTEMPTED, DROPPED
		error_details nvarchar(MAX) NULL, 
		CONSTRAINT PK_restore_log PRIMARY KEY CLUSTERED (restore_test_id)
	);

END;


----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Deploy new code:


USE [admindb];
GO

IF OBJECT_ID('dbo.check_paths','P') IS NOT NULL
	DROP PROC dbo.check_paths;
GO

CREATE PROC dbo.check_paths 
	@Path				nvarchar(MAX),
	@Exists				bit					OUTPUT
AS
	SET NOCOUNT ON;

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	SET @Exists = 0;

	DECLARE @results TABLE (
		[output] varchar(500)
	);

	DECLARE @command nvarchar(2000) = N'IF EXIST "' + @Path + N'" ECHO EXISTS';

	INSERT INTO @results ([output])  
	EXEC sys.xp_cmdshell @command;

	IF EXISTS (SELECT NULL FROM @results WHERE [output] = 'EXISTS')
		SET @Exists = 1;

	RETURN 0;
GO


USE [admindb];
GO

IF OBJECT_ID('dbo.execute_uncatchable_command','P') IS NOT NULL
	DROP PROC dbo.execute_uncatchable_command;
GO

CREATE PROC dbo.execute_uncatchable_command
	@statement				varchar(4000), 
	@filterType				varchar(20), 
	@result					varchar(4000)			OUTPUT	
AS
	SET NOCOUNT ON;

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	IF @filterType NOT IN ('BACKUP','RESTORE','CREATEDIR','ALTER','DROP','DELETEFILE') BEGIN;
		RAISERROR('Configuration Problem: Non-Supported @filterType value specified.', 16, 1);
		SET @result = 'Configuration Problem with dba_ExecuteAndFilterNonCatchableCommand.';
		RETURN -1;
	END 

	DECLARE @filters table (
		filter_text varchar(200) NOT NULL, 
		filter_type varchar(20) NOT NULL
	);

	INSERT INTO @filters (filter_text, filter_type)
	VALUES 
	-- BACKUP:
	('Processed % pages for database %', 'BACKUP'),
	('BACKUP DATABASE successfully processed % pages in %','BACKUP'),
	('BACKUP DATABASE WITH DIFFERENTIAL successfully processed % pages in %', 'BACKUP'),
	('BACKUP LOG successfully processed % pages in %', 'BACKUP'),
	('The log was not truncated because records at the beginning %sp_repldone% to mark transactions as distributed %', 'BACKUP'),  -- NOTE: should only be enabled on systems where there's a JOB to force cleanup of replication in log... 

	-- RESTORE:
	('RESTORE DATABASE successfully processed % pages in %', 'RESTORE'),
	('RESTORE LOG successfully processed % pages in %', 'RESTORE'),
	('Processed % pages for database %', 'RESTORE'),
		-- whenever there's a patch or upgrade...
	('Converting database % from version % to the current version %', 'RESTORE'), 
	('Database % running the upgrade step from version % to version %.', 'RESTORE'),

	-- CREATEDIR:
	('Command(s) completed successfully.', 'CREATEDIR'), 

	-- ALTER:
	('Command(s) completed successfully.', 'ALTER'),
	('Nonqualified transactions are being rolled back. Estimated rollback completion%', 'ALTER'), 

	-- DROP:
	('Command(s) completed successfully.', 'DROP'),

	-- DELETEFILE:
	('Command(s) completed successfully.','DELETEFILE')

	-- add other filters here as needed... 
	;

	DECLARE @delimiter nchar(4) = N' -> ';

	CREATE TABLE #Results (
		result_id int IDENTITY(1,1),
		result nvarchar(MAX)
	);

	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @command varchar(2000) = 'sqlcmd {0} -q "' + REPLACE(@statement, @crlf, ' ') + '"';

	-- Account for named instances:
	DECLARE @serverName sysname = '';
	IF @@SERVICENAME != N'MSSQLSERVER'
		SET @serverName = N' -S .\' + @@SERVICENAME;
		
	SET @command = REPLACE(@command, '{0}', @serverName);

	--PRINT @command;

	INSERT INTO #Results (result)
	EXEC master..xp_cmdshell @command;

	DELETE r
	FROM 
		#Results r 
		INNER JOIN @filters x ON x.filter_type = @filterType AND r.RESULT LIKE x.filter_text;

	IF EXISTS (SELECT NULL FROM #Results WHERE result IS NOT NULL) BEGIN;
		SET @result = '';
		SELECT @result = @result + result + @delimiter FROM #Results WHERE result IS NOT NULL ORDER BY result_id;
		SET @result = LEFT(@result, LEN(@result) - LEN(@delimiter));
	END

	RETURN 0;
GO


USE [admindb];
GO

IF OBJECT_ID('dbo.load_database_names','P') IS NOT NULL
	DROP PROC dbo.load_database_names;
GO

CREATE PROC dbo.load_database_names 
	@Input				nvarchar(MAX),				-- [SYSTEM] | [USER] | [READ_FROM_FILESYSTEM] | comma,delimited,list, of, databases, where, spaces, do,not,matter
	@Exclusions			nvarchar(MAX)	= NULL,		-- comma, delimited, list, of, db, names, %wildcards_allowed%
	@Priorities			nvarchar(MAX)	= NULL,		-- higher,priority,dbs,*,lower,priority, dbs  (where * is an ALPHABETIZED list of all dbs that don't match a priority (positive or negative)). If * is NOT specified, the following is assumed: high, priority, dbs, [*]
	@Mode				sysname,					-- BACKUP | RESTORE | REMOVE | CHECKUP
	@BackupType			sysname			= NULL,		-- FULL | DIFF | LOG  -- only needed if @Mode = BACKUP
	@TargetDirectory	sysname			= NULL, 
	@Output				nvarchar(MAX)	OUTPUT
AS
	SET NOCOUNT ON; 

	DECLARE @includeAdminDBAsSystemDatabase bit = 1; -- by default, tread admindb as a system database (i.e., exclude it from [USER] and include it in [SYSTEM];

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF ISNULL(@Input, N'') = N'' BEGIN;
		RAISERROR('@Input cannot be null or empty - it must either be the specialized token [SYSTEM], [USER], [READ_FROM_FILESYSTEM], or a comma-delimited list of databases/folders.', 16, 1);
		RETURN -1;
	END

	IF ISNULL(@Mode, N'') = N'' BEGIN;
		RAISERROR('@Mode cannot be null or empty - it must be one of the following values: BACKUP | RESTORE | REMOVE | CHECKUP', 16, 1);
		RETURN -2;
	END
	
	IF UPPER(@Mode) NOT IN (N'BACKUP',N'RESTORE',N'REMOVE',N'CHECKUP') BEGIN 
		RAISERROR('Permitted values for @Mode must be one of the following values: BACKUP | RESTORE | REMOVE | CHECKUP', 16, 1);
		RETURN -2;
	END

	IF UPPER(@Mode) = N'BACKUP' BEGIN;
		IF @BackupType IS NULL BEGIN;
			RAISERROR('When @Mode is set to BACKUP, the @BackupType value MUST be provided (and must be one of the following values: FULL | DIFF | LOG).', 16, 1);
			RETURN -5;
		END

		IF UPPER(@BackupType) NOT IN (N'FULL', N'DIFF', N'LOG') BEGIN;
			RAISERROR('When @Mode is set to BACKUP, the @BackupType value MUST be provided (and must be one of the following values: FULL | DIFF | LOG).', 16, 1);
			RETURN -5;
		END
	END

	IF UPPER(@Input) = N'[READ_FROM_FILESYSTEM]' BEGIN;
		IF UPPER(@Mode) NOT IN (N'RESTORE', N'REMOVE') BEGIN;
			RAISERROR('The specialized token [READ_FROM_FILESYSTEM] can only be used when @Mode is set to RESTORE or REMOVE.', 16, 1);
			RETURN - 9;
		END

		IF @TargetDirectory IS NULL BEGIN;
			RAISERROR('When @Input is specified as [READ_FROM_FILESYSTEM], the @TargetDirectory must be specified - and must point to a valid path.', 16, 1);
			RETURN - 10;
		END
	END

	-----------------------------------------------------------------------------
	-- Initialize helper objects:

	SELECT TOP 1000 IDENTITY(int, 1, 1) as N 
    INTO #Tally
    FROM sys.columns;

    DECLARE @targets TABLE ( 
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [database_name] sysname NOT NULL
    ); 

    IF UPPER(@Input) = '[SYSTEM]' BEGIN;
	    INSERT INTO @targets ([database_name])
        SELECT 'master' UNION SELECT 'msdb' UNION SELECT 'model';

		IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = 'admindb') BEGIN
			IF @includeAdminDBAsSystemDatabase = 1 
				INSERT INTO @targets ([database_name])
				VALUES ('admindb');
		END
    END; 

    IF UPPER(@Input) = '[USER]' BEGIN; 
        IF @BackupType = 'LOG'
            INSERT INTO @targets ([database_name])
            SELECT name FROM sys.databases 
            WHERE recovery_model_desc = 'FULL' 
                AND name NOT IN ('master', 'model', 'msdb', 'tempdb') 
            ORDER BY name;
        ELSE 
            INSERT INTO @targets ([database_name])
            SELECT name FROM sys.databases 
            WHERE name NOT IN ('master', 'model', 'msdb','tempdb') 
            ORDER BY name;

		IF @includeAdminDBAsSystemDatabase = 1 
			DELETE FROM @targets WHERE [database_name] = 'admindb';
    END; 

    IF UPPER(@Input) = '[READ_FROM_FILESYSTEM]' BEGIN;

        DECLARE @directories table (
            row_id int IDENTITY(1,1) NOT NULL, 
            subdirectory sysname NOT NULL, 
            depth int NOT NULL
        );

        INSERT INTO @directories (subdirectory, depth)
        EXEC master.sys.xp_dirtree @TargetDirectory, 1, 0;

        INSERT INTO @targets ([database_name])
        SELECT subdirectory FROM @directories ORDER BY row_id;

      END; 

    IF (SELECT COUNT(*) FROM @targets) <= 0 BEGIN;

        DECLARE @SerializedDbs nvarchar(1200);
		SET @SerializedDbs = N',' + @Input + N',';

        INSERT INTO @targets ([database_name])
        SELECT  RTRIM(LTRIM((SUBSTRING(@SerializedDbs, N + 1, CHARINDEX(',', @SerializedDbs, N + 1) - N - 1))))
        FROM #Tally
        WHERE N < LEN(@SerializedDbs) 
            AND SUBSTRING(@SerializedDbs, N, 1) = ','
        ORDER BY #Tally.N;

		IF UPPER(@Mode) = N'BACKUP' BEGIN;
			IF @BackupType = 'LOG' BEGIN
				DELETE FROM @targets 
				WHERE [database_name] NOT IN (
					SELECT name FROM sys.databases WHERE recovery_model_desc = 'FULL'
				);
			  END;
			ELSE 
				DELETE FROM @targets
				WHERE [database_name] NOT IN (SELECT name FROM sys.databases);
		END
    END;

	IF UPPER(@Mode) IN (N'BACKUP') BEGIN;
		-- Exclude any databases that aren't operational: (NOTE, this excluding all dbs that are non-operational INCLUDING those that might be 'out' because of Mirroring, but it is NOT SOLELY trying to remove JUST mirrored/AG'd databases)
		DELETE FROM @targets 
		WHERE [database_name] IN (SELECT name FROM sys.databases WHERE state_desc != 'ONLINE')  -- this gets any dbs that are NOT online - INCLUDING those that are listed as 'RESTORING' because of mirroring. 
			OR [database_name] IN (
				SELECT d.name 
				FROM sys.databases d 
				INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id
				WHERE hars.role_desc != 'PRIMARY'
			); -- grab any dbs that are in an AG where the current role != PRIMARY. 
	END

	-- Exclude any databases specified for exclusion:
	IF ISNULL(@Exclusions, '') != '' BEGIN;
	
		DECLARE @removedDbs nvarchar(1200);
		SET @removedDbs = N',' + @Exclusions + N',';

		DELETE t 
		FROM @targets t 
		INNER JOIN (
			SELECT RTRIM(LTRIM(SUBSTRING(@removedDbs, N + 1, CHARINDEX(',', @removedDbs, N + 1) - N - 1))) [db_name]
			FROM #Tally
			WHERE N < LEN(@removedDbs)
				AND SUBSTRING(@removedDbs, N, 1) = ','		
		) exclusions ON t.[database_name] LIKE exclusions.[db_name];

	END;

	IF ISNULL(@Priorities, '') IS NOT NULL BEGIN;
		DECLARE @SerializedPriorities nvarchar(MAX);
		SET @SerializedPriorities = N',' + @Priorities + N',';

		DECLARE @prioritized table (
			priority_id int IDENTITY(1,1) NOT NULL, 
			[database_name] sysname NOT NULL
		);

		INSERT INTO @prioritized ([database_name])
		SELECT  RTRIM(LTRIM((SUBSTRING(@SerializedPriorities, N + 1, CHARINDEX(',', @SerializedPriorities, N + 1) - N - 1))))
        FROM #Tally
        WHERE N < LEN(@SerializedPriorities) 
            AND SUBSTRING(@SerializedPriorities, N, 1) = ','
        ORDER BY #Tally.N;

		DECLARE @alphabetized int;
		SELECT @alphabetized = priority_id FROM @prioritized WHERE [database_name] = '*';

		IF @alphabetized IS NULL
			SET @alphabetized = (SELECT MAX(entry_id) + 1 FROM @targets);

		DECLARE @prioritized_targets TABLE ( 
			[entry_id] int IDENTITY(1,1) NOT NULL, 
			[database_name] sysname NOT NULL
		); 

		WITH core AS ( 
			SELECT 
				t.[database_name], 
				CASE 
					WHEN p.[database_name] IS NULL THEN 0 + t.entry_id
					WHEN p.[database_name] IS NOT NULL AND p.priority_id <= @alphabetized THEN -32767 + p.priority_id
					WHEN p.[database_name] IS NOT NULL AND p.priority_id > @alphabetized THEN 32767 + p.priority_id
				END [prioritized_priority]
			FROM 
				@targets t 
				LEFT OUTER JOIN @prioritized p ON p.[database_name] = t.[database_name]
		) 

		INSERT INTO @prioritized_targets ([database_name])
		SELECT 
			[database_name]
		FROM core 
		ORDER BY 
			core.prioritized_priority;

		DELETE FROM @targets;
		INSERT INTO @targets ([database_name])
		SELECT [database_name] 
		FROM @prioritized_targets
		ORDER BY entry_id;

	END 

	-- Output (used to get around nasty 'insert exec can't be nested' error when reading from file-system.
	SET @Output = N'';
	SELECT @Output = @Output + [database_name] + ',' FROM @targets ORDER BY entry_id;

	IF ISNULL(@Output,'') != ''
		SET @Output = LEFT(@Output, LEN(@Output) - 1);

	RETURN 0;
GO


USE [admindb];
GO


IF OBJECT_ID('dbo.split_string','TF') IS NOT NULL
	DROP FUNCTION dbo.split_string;
GO

CREATE FUNCTION dbo.split_string(@serialized nvarchar(MAX), @delimiter nvarchar(20))
RETURNS @Results TABLE (result nvarchar(200))
	--WITH SCHEMABINDING 
AS 
	BEGIN

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )
	
	IF NULLIF(@serialized,'') IS NOT NULL BEGIN

		DECLARE @MaxLength int;
		SET @MaxLength = LEN(@serialized) + 1000;

		SET @serialized = @delimiter + @serialized + @delimiter;

		WITH tally AS ( 
			SELECT TOP (@MaxLength) 
				ROW_NUMBER() OVER (ORDER BY o1.[name]) AS n
			FROM sys.all_objects o1 
			CROSS JOIN sys.all_objects o2
		)

		INSERT INTO @Results (result)
		SELECT  RTRIM(LTRIM((SUBSTRING(@serialized, n + 1, CHARINDEX(@delimiter, @serialized, n + 1) - n - 1))))
		FROM tally t
		WHERE n < LEN(@serialized) 
			AND SUBSTRING(@serialized, n, 1) = @delimiter
		ORDER BY t.n;
	END;

	RETURN;
END

GO



USE [admindb];
GO

IF OBJECT_ID('[dbo].[remove_backup_files]','P') IS NOT NULL
	DROP PROC [dbo].[remove_backup_files];
GO

CREATE PROC [dbo].[remove_backup_files] 
	@BackupType							sysname,						-- { ALL | FULL|DIFF|LOG }
	@DatabasesToProcess					nvarchar(1000),					-- { [READ_FROM_FILESYSTEM] | name1,name2,etc }
	@DatabasesToExclude					nvarchar(600) = NULL,			-- { NULL | name1,name2 }  
	@TargetDirectory					nvarchar(2000),					-- { path_to_backups }
	@Retention							nvarchar(10),					-- #n  - where # is an integer for the threshold, and n is either m, h, d, w, or b - for Minutes, Hours, Days, Weeks, or B - for # of backups to retain.
	@Output								nvarchar(MAX) = NULL OUTPUT,	-- When set to non-null value, summary/errors/output will be 'routed' into this variable instead of emailed/raised/etc.
	@SendNotifications					bit	= 0,						-- { 0 | 1 } Email only sent if set to 1 (true).
	@OperatorName						sysname = N'Alerts',		
	@MailProfileName					sysname = N'General',
	@EmailSubjectPrefix					nvarchar(50) = N'[Backups Cleanup ] ',
	@PrintOnly							bit = 0 						-- { 0 | 1 }
AS
	SET NOCOUNT ON; 

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	IF OBJECT_ID('dbo.execute_uncatchable_command', 'P') IS NULL BEGIN;
		RAISERROR('Stored Procedure dbo.execute_uncatchable_command not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dbo.split_string', 'TF') IS NULL BEGIN;
		RAISERROR('Table-Valued Function dbo.split_string not defined - unable to continue.', 16, 1);
		RETURN -1;
	END

	IF OBJECT_ID('dbo.load_database_names', 'P') IS NULL BEGIN;
		RAISERROR('Stored Procedure dbo.load_database_names not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	DECLARE @Edition sysname;
	SELECT @Edition = CASE SERVERPROPERTY('EngineEdition')
		WHEN 2 THEN 'STANDARD'
		WHEN 3 THEN 'ENTERPRISE'
		WHEN 4 THEN 'EXPRESS'
		ELSE NULL
	END;

	IF @Edition = N'STANDARD' OR @Edition IS NULL BEGIN;
		-- check for Web:
		IF @@VERSION LIKE '%web%' SET @Edition = 'WEB';
	END;
	
	IF @Edition IS NULL BEGIN;
		RAISERROR('Unsupported SQL Server Edition detected. This script is only supported on Express, Web, Standard, and Enterprise (including Evaluation and Developer) Editions.', 16, 1);
		RETURN -2;
	END;

	IF EXISTS (SELECT NULL FROM sys.configurations WHERE name = 'xp_cmdshell' AND value_in_use = 0) BEGIN;
		RAISERROR('xp_cmdshell is not currently enabled.', 16,1);
		RETURN -3;
	END;

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF ((@PrintOnly = 0) OR (@Output IS NULL)) AND (@Edition != 'EXPRESS') BEGIN; -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 

		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN;
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -4;
		 END;
		ELSE BEGIN; 
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN;
				RAISERROR('Invalid Operator Name Specified.', 16, 1);
				RETURN -4;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255);
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN;
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	IF NULLIF(@TargetDirectory, N'') IS NULL BEGIN;
		RAISERROR('@BackupsDirectory cannot be NULL and must be a valid path.', 16, 1);
		RETURN -6;
	END;

	IF UPPER(@BackupType) NOT IN ('FULL', 'DIFF', 'LOG', 'ALL') BEGIN;
		PRINT 'Usage: @BackupType = FULL|DIFF|LOG';
		RAISERROR('Invalid @BackupType Specified.', 16, 1);

		RETURN -7;
	END;

	SET @Retention = LTRIM(RTRIM(@Retention));
	DECLARE @retentionType char(1);
	DECLARE @retentionValue int;

	SET @retentionType = LOWER(RIGHT(@Retention,1));

	-- Only approved values are allowed: (m[inutes], [h]ours, [d]ays, [b]ackups (a specific count)). 
	IF @retentionType NOT IN ('m','h','d','w','b') BEGIN 
		RAISERROR('Invalid @Retention value specified. @Retention must take the format of #L - where # is a positive integer, and L is a SINGLE letter [m | h | d | w | b] for minutes, hours, days, weeks, or backups (i.e., a specific number of most recent backups to retain).', 16, 1);
		RETURN -10000;	
	END 

	-- a WHOLE lot of negation going on here... but, this is, insanely, right:
	IF NOT EXISTS (SELECT 1 WHERE LEFT(@Retention, LEN(@Retention) - 1) NOT LIKE N'%[^0-9]%') BEGIN 
		RAISERROR('Invalid @Retention specified defined (more than one non-integer value found in @Retention value). Please specify an integer and then either [ m | h | d | w | b ] for minutes, hours, days, weeks, or backups (specific number of most recent backups) to retain.', 16, 1);
		RETURN -10001;
	END
	
	SET @retentionValue = CAST(LEFT(@Retention, LEN(@Retention) -1) AS int);

	IF @retentionType = 'b'
		PRINT 'Retention specification is to keep the last ' + CAST(@retentionValue AS sysname) + ' backup(s).';
	ELSE 
		PRINT 'Retention specification is to remove backups more than ' + CAST(@retentionValue AS sysname) + CASE @retentionType WHEN 'm' THEN ' minutes ' WHEN 'h' THEN ' hour(s) ' WHEN 'd' THEN ' day(s) ' ELSE ' week(s) ' END + 'old.';

	DECLARE @retentionCutoffTime datetime = NULL; 
	IF @retentionType != 'b' BEGIN
		IF @retentionType = 'm'
			SET @retentionCutoffTime = DATEADD(MINUTE, 0 - @retentionValue, GETDATE());

		IF @retentionType = 'h'
			SET @retentionCutoffTime = DATEADD(HOUR, 0 - @retentionValue, GETDATE());

		IF @retentionType = 'd'
			SET @retentionCutoffTime = DATEADD(DAY, 0 - @retentionValue, GETDATE());

		IF @retentionType = 'w'
			SET @retentionCutoffTime = DATEADD(WEEK, 0 - @retentionValue, GETDATE());
		
		IF @RetentionCutoffTime >= GETDATE() BEGIN; 
			 RAISERROR('Invalid @Retention specification. Specified value is in the future.', 16, 1);
			 RETURN -10;
		END;		
	END

	-- normalize paths: 
	IF(RIGHT(@TargetDirectory, 1) = '\')
		SET @TargetDirectory = LEFT(@TargetDirectory, LEN(@TargetDirectory) - 1);

	-- verify that path exists:
	DECLARE @isValid bit;
	EXEC dbo.check_paths @TargetDirectory, @isValid OUTPUT;
	IF @isValid = 0 BEGIN;
		RAISERROR('Invalid @TargetDirectory specified - either the path does not exist, or SQL Server''s Service Account does not have permissions to access the specified directory.', 16, 1);
		RETURN -10;
	END

	-----------------------------------------------------------------------------
	DECLARE @routeInfoAsOutput bit = 0;
	IF @Output IS NOT NULL 
		SET @routeInfoAsOutput = 1; 

	SET @Output = NULL;

	DECLARE @serialized nvarchar(MAX);
	EXEC dbo.load_database_names
	    @Input = @DatabasesToProcess,
	    @Exclusions = @DatabasesToExclude,
	    @Mode = N'REMOVE',
	    @BackupType = @BackupType, 
		@TargetDirectory = @TargetDirectory,
		@Output = @serialized OUTPUT;

	DECLARE @targetDirectories table (
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [directory_name] sysname NOT NULL
    ); 

	INSERT INTO @targetDirectories ([directory_name])
	SELECT [result] FROM dbo.split_string(@serialized, N',');

	-----------------------------------------------------------------------------
	-- Process files for removal:

	DECLARE @currentDirectory sysname;
	DECLARE @command nvarchar(MAX);
	DECLARE @targetPath nvarchar(512);
	DECLARE @outcome varchar(4000);
	DECLARE @errorMessage nvarchar(MAX) = N'';
	DECLARE @file nvarchar(512);

	DECLARE @files table (
		id int IDENTITY(1,1),
		subdirectory nvarchar(512), 
		depth int, 
		isfile bit
	);

	DECLARE @lastN table ( 
		id int IDENTITY(1,1) NOT NULL, 
		original_id int NOT NULL, 
		backup_name nvarchar(512), 
		backup_type sysname
	);

	DECLARE @errors table (
		error_id int IDENTITY(1,1) NOT NULL, 
		[error_message] nvarchar(MAX) NOT NULL
	);

	DECLARE processor CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		directory_name
	FROM 
		@targetDirectories
	ORDER BY 
		[entry_id];

	OPEN processor;

	FETCH NEXT FROM processor INTO @currentDirectory;

	WHILE @@FETCH_STATUS = 0 BEGIN;
		
		SET @targetPath = @TargetDirectory + N'\' + @currentDirectory;

		SET @errorMessage = NULL;
		SET @outcome = NULL;

		IF @retentionType = 'b' BEGIN -- Remove all backups of target type except the most recent N (where N is @retentionValue).
			
			-- clear out any state from previous iterations.
			DELETE FROM @files;
			DELETE FROM @lastN;

			SET @command = N'EXEC master.sys.xp_dirtree ''' + @targetPath + ''', 1, 1;';

			IF @PrintOnly = 1
				PRINT N'--' + @command;

			INSERT INTO @files (subdirectory, depth, isfile)
			EXEC sys.sp_executesql @command;

			-- Remove non-matching files/entries:
			DELETE FROM @files WHERE isfile = 0; -- remove directories.

			IF @BackupType IN ('LOG', 'ALL') BEGIN
				INSERT INTO @lastN (original_id, backup_name, backup_type)
				SELECT TOP (@retentionValue)
					id, 
					subdirectory, 
					'LOG'
				FROM 
					@files
				WHERE 
					subdirectory LIKE 'LOG%.trn'
				ORDER BY 
					id DESC;

				IF @BackupType != 'ALL' BEGIN
					DELETE FROM @files WHERE subdirectory NOT LIKE '%.trn';  -- if we're NOT doing all, then remove DIFF and FULL backups... 
				END;
			END;

			IF @BackupType IN ('FULL', 'ALL') BEGIN
				INSERT INTO @lastN (original_id, backup_name, backup_type)
				SELECT TOP (@retentionValue)
					id, 
					subdirectory, 
					'FULL'
				FROM 
					@files
				WHERE 
					subdirectory LIKE 'FULL%.bak'
				ORDER BY 
					id DESC;

				IF @BackupType != 'ALL' BEGIN 
					DELETE FROM @files WHERE subdirectory NOT LIKE 'FULL%.bak'; -- if we're NOT doing all, then remove all non-FULL backups...  
				END
			END;

			IF @BackupType IN ('DIFF', 'ALL') BEGIN
				INSERT INTO @lastN (original_id, backup_name, backup_type)
				SELECT TOP (@retentionValue)
					id, 
					subdirectory, 
					'DIFF'
				FROM 
					@files
				WHERE 
					subdirectory LIKE 'DIFF%.bak'
				ORDER BY 
					id DESC;

					IF @BackupType != 'ALL' BEGIN 
						DELETE FROM @files WHERE subdirectory NOT LIKE 'DIFF%.bak'; -- if we're NOT doing all, the remove non-DIFFs so they won't be nuked.
					END
			END;
			
			-- prune any/all files we're supposed to keep: 
			DELETE x 
			FROM 
				@files x 
				INNER JOIN @lastN l ON x.id = l.original_id AND x.subdirectory = l.backup_name;

			-- and delete all, enumerated, files that are left:
			DECLARE nuker CURSOR LOCAL FAST_FORWARD FOR 
			SELECT subdirectory FROM @files ORDER BY id;

			OPEN nuker;
			FETCH NEXT FROM nuker INTO @file;

			WHILE @@FETCH_STATUS = 0 BEGIN;

				-- reset per each 'grab':
				SET @errorMessage = NULL;
				SET @outcome = NULL

				SET @command = N'EXECUTE master.sys.xp_delete_file 0, N''' + @targetPath + N'\' + @file + ''', N''bak'', N''' + REPLACE(CONVERT(nvarchar(20), GETDATE(), 120), ' ', 'T') + ''', 0;';

				IF @PrintOnly = 1 
					PRINT @command;
				ELSE BEGIN; 

					BEGIN TRY
						EXEC dbo.execute_uncatchable_command @command, 'DELETEFILE', @result = @outcome OUTPUT;
						
						IF @outcome IS NOT NULL 
							SET @errorMessage = ISNULL(@errorMessage, '')  + @outcome + N' ';

					END TRY 
					BEGIN CATCH
						SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected error deleting backup [' + @file + N'] from [' + @targetPath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
					END CATCH

				END;

				IF @errorMessage IS NOT NULL BEGIN;
					SET @errorMessage = ISNULL(@errorMessage, '') + '. Command: [' + ISNULL(@command, '#EMPTY#') + N']. ';

					INSERT INTO @errors ([error_message])
					VALUES (@errorMessage);
				END

				FETCH NEXT FROM nuker INTO @file;

			END;

			CLOSE nuker;
			DEALLOCATE nuker;
		  END;
		ELSE BEGIN -- Any backups older than @RetentionCutoffTime are removed. 

			IF @BackupType IN ('LOG', 'ALL') BEGIN;
			
				SET @command = N'EXECUTE master.sys.xp_delete_file 0, N''' + @targetPath + ''', N''trn'', N''' + REPLACE(CONVERT(nvarchar(20), @RetentionCutoffTime, 120), ' ', 'T') + ''', 1;';

				IF @PrintOnly = 1 
					PRINT @command;
				ELSE BEGIN 
					BEGIN TRY
						EXEC dbo.execute_uncatchable_command @command, 'DELETEFILE', @result = @outcome OUTPUT;

						IF @outcome IS NOT NULL 
							SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';

					END TRY 
					BEGIN CATCH
						SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected error deleting older LOG backups from [' + @targetPath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

					END CATCH;				
				END

				IF @errorMessage IS NOT NULL BEGIN;
					SET @errorMessage = ISNULL(@errorMessage, '') + N' [Command: ' + @command + N']';

					INSERT INTO @errors ([error_message])
					VALUES (@errorMessage);
				END
			END

			IF @BackupType IN ('FULL', 'DIFF', 'ALL') BEGIN;

				-- start by clearing any previous values:
				DELETE FROM @files;
				SET @command = N'EXEC master.sys.xp_dirtree ''' + @targetPath + ''', 1, 1;';

				IF @PrintOnly = 1
					PRINT N'--' + @command;

				INSERT INTO @files (subdirectory, depth, isfile)
				EXEC sys.sp_executesql @command;

				DELETE FROM @files WHERE isfile = 0; -- remove directories.
				DELETE FROM @files WHERE subdirectory NOT LIKE '%.bak'; -- remove (from processing) any files that don't use the .bak extension. 

				-- If a specific backup type is specified ONLY target that backup type:
				IF @BackupType != N'ALL' BEGIN;
				
					IF @BackupType = N'FULL'
						DELETE FROM @files WHERE subdirectory NOT LIKE N'FULL%';

					IF @BackupType = N'DIFF'
						DELETE FROM @files WHERE subdirectory NOT LIKE N'DIFF%';
				END

				DECLARE nuker CURSOR LOCAL FAST_FORWARD FOR 
				SELECT subdirectory FROM @files WHERE isfile = 1 AND subdirectory NOT LIKE '%.trn' ORDER BY id;

				OPEN nuker;
				FETCH NEXT FROM nuker INTO @file;

				WHILE @@FETCH_STATUS = 0 BEGIN;

					-- reset per each 'grab':
					SET @errorMessage = NULL;
					SET @outcome = NULL

					SET @command = N'EXECUTE master.sys.xp_delete_file 0, N''' + @targetPath + N'\' + @file + ''', N''bak'', N''' + REPLACE(CONVERT(nvarchar(20), @RetentionCutoffTime, 120), ' ', 'T') + ''', 0;';

					IF @PrintOnly = 1 
						PRINT @command;
					ELSE BEGIN; 

						BEGIN TRY
							EXEC dbo.execute_uncatchable_command @command, 'DELETEFILE', @result = @outcome OUTPUT;
						
							IF @outcome IS NOT NULL 
								SET @errorMessage = ISNULL(@errorMessage, '')  + @outcome + N' ';

						END TRY 
						BEGIN CATCH
							SET @errorMessage = ISNULL(@errorMessage, '') +  N'Error deleting DIFF/FULL Backup with command: [' + ISNULL(@command, '##NOT SET YET##') + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
						END CATCH

					END;

					IF @errorMessage IS NOT NULL BEGIN;
						SET @errorMessage = ISNULL(@errorMessage, '') + '. Command: [' + ISNULL(@command, '#EMPTY#') + N']. ';

						INSERT INTO @errors ([error_message])
						VALUES (@errorMessage);
					END

					FETCH NEXT FROM nuker INTO @file;
				END;

				CLOSE nuker;
				DEALLOCATE nuker;

		    END
		END;

		FETCH NEXT FROM processor INTO @currentDirectory;
	END

	CLOSE processor;
	DEALLOCATE processor;

	-----------------------------------------------------------------------------
	-- Cleanup:
	IF (SELECT CURSOR_STATUS('local','nuker')) > -1 BEGIN;
		CLOSE nuker;
		DEALLOCATE nuker;
	END;

	-----------------------------------------------------------------------------
	-- Error Reporting:
	DECLARE @errorInfo nvarchar(MAX) = N'';
	DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
	DECLARE @tab nchar(1) = CHAR(9);

	IF EXISTS (SELECT NULL FROM @errors) BEGIN;
		
		-- format based on output type (output variable or email/error-message), then 'raise, return, or send'... 
		IF @routeInfoAsOutput = 1 BEGIN;
			SELECT @errorInfo = @errorInfo + [error_message] + N', ' FROM @errors ORDER BY error_id;
			SET @errorInfo = LEFT(@errorInfo, LEN(@errorInfo) - 2);

			SET @output = @errorInfo;
		  END
		ELSE BEGIN;

			SELECT @errorInfo = @errorInfo + @tab + N'- ' + [error_message] + @crlf + @crlf
			FROM 
				@errors
			ORDER BY 
				error_id;

			IF (@SendNotifications = 1) AND (@Edition != 'EXPRESS') BEGIN;
				DECLARE @emailSubject nvarchar(2000);
				SET @emailSubject = @EmailSubjectPrefix + N' - ERROR';

				SET @errorInfo = N'The following errors were encountered: ' + @crlf + @errorInfo;

				EXEC msdb..sp_notify_operator
					@profile_name = @MailProfileName,
					@name = @OperatorName,
					@subject = @emailSubject, 
					@body = @errorInfo;				
			END

			-- this is being executed as a stand-alone job (most likely) so... throw the output into the job's history... 
			PRINT @errorInfo;  
			
			RAISERROR(@errorMessage, 16, 1);
			RETURN -100;
		END
	END;

	RETURN 0;
GO


USE [admindb];
GO

IF OBJECT_ID('dbo.backup_databases','P') IS NOT NULL
	DROP PROC dbo.backup_databases;
GO

CREATE PROC dbo.backup_databases 
	@BackupType							sysname,					-- { FULL|DIFF|LOG }
	@DatabasesToBackup					nvarchar(MAX),				-- { [SYSTEM]|[USER]|name1,name2,etc }
	@DatabasesToExclude					nvarchar(MAX) = NULL,		-- { NULL | name1,name2 }  
	@Priorities							nvarchar(MAX) = NULL,		-- { higher,priority,dbs,*,lower,priority,dbs } - where * represents dbs not specifically specified (which will then be sorted alphabetically
	@BackupDirectory					nvarchar(2000),				-- { path_to_backups }
	@CopyToBackupDirectory				nvarchar(2000) = NULL,		-- { NULL | path_for_backup_copies } 
	@BackupRetention					nvarchar(10),				-- [DOCUMENT HERE]
	@CopyToRetention					nvarchar(10) = NULL,		-- [DITTO: As above, but allows for diff retention settings to be configured for copied/secondary backups.]
	@RemoveFilesBeforeBackup			bit = 0,					-- { 0 | 1 } - when true, then older backups will be removed BEFORE backups are executed.
	@EncryptionCertName					sysname = NULL,				-- Ignored if not specified. 
	@EncryptionAlgorithm				sysname = NULL,				-- Required if @EncryptionCertName is specified. AES_256 is best option in most cases.
	@AddServerNameToSystemBackupPath	bit	= 0,					-- If set to 1, backup path is: @BackupDirectory\<db_name>\<server_name>\
	@AllowNonAccessibleSecondaries		bit = 0,					-- If review of @DatabasesToBackup yields no dbs (in a viable state) for backups, exception thrown - unless this value is set to 1 (for AGs, Mirrored DBs) and then execution terminates gracefully with: 'No ONLINE dbs to backup'.
	@LogSuccessfulOutcomes				bit = 0,					-- By default, exceptions/errors are ALWAYS logged. If set to true, successful outcomes are logged to dba_DatabaseBackup_logs as well.
	@OperatorName						sysname = N'Alerts',
	@MailProfileName					sysname = N'General',
	@EmailSubjectPrefix					nvarchar(50) = N'[Database Backups ] ',
	@PrintOnly							bit = 0						-- Instead of EXECUTING commands, they're printed to the console only. 	
AS
	SET NOCOUNT ON;

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	IF OBJECT_ID('dbo.backup_log', 'U') IS NULL BEGIN
		RAISERROR('S4 Table dbo.backup_log not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dbo.split_string', 'TF') IS NULL BEGIN
		RAISERROR('S4 Table-Valued Function dbo.split_string not defined - unable to continue.', 16, 1);
		RETURN -1;
	END

	IF OBJECT_ID('dbo.load_database_names', 'P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.load_database_names not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dbo.check_paths', 'P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.check_paths not defined - unable to continue.', 16, 1);
		RETURN -1;
	END

	IF OBJECT_ID('dbo.execute_uncatchable_command', 'P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.execute_uncatchable_command not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	DECLARE @Edition sysname;
	SELECT @Edition = CASE SERVERPROPERTY('EngineEdition')
		WHEN 2 THEN 'STANDARD'
		WHEN 3 THEN 'ENTERPRISE'
		WHEN 4 THEN 'EXPRESS'
		ELSE NULL
	END;

	IF @Edition = N'STANDARD' OR @Edition IS NULL BEGIN
		-- check for Web:
		IF @@VERSION LIKE '%web%' SET @Edition = 'WEB';
	END;
	
	IF @Edition IS NULL BEGIN
		RAISERROR('Unsupported SQL Server Edition detected. This script is only supported on Express, Web, Standard, and Enterprise (including Evaluation and Developer) Editions.', 16, 1);
		RETURN -2;
	END;

	IF EXISTS (SELECT NULL FROM sys.configurations WHERE name = 'xp_cmdshell' AND value_in_use = 0) BEGIN
		RAISERROR('xp_cmdshell is not currently enabled.', 16,1);
		RETURN -3;
	END;

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF (@PrintOnly = 0) AND (@Edition != 'EXPRESS') BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 

		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -4;
		 END;
		ELSE BEGIN
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
				RAISERROR('Invalid Operator Name Specified.', 16, 1);
				RETURN -4;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255);
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	IF NULLIF(@BackupDirectory, N'') IS NULL BEGIN
		RAISERROR('@BackupsDirectory cannot be NULL and must be a valid path.', 16, 1);
		RETURN -6;
	END;

	IF UPPER(@BackupType) NOT IN ('FULL', 'DIFF', 'LOG') BEGIN
		PRINT 'Usage: @BackupType = FULL|DIFF|LOG';
		RAISERROR('Invalid @BackupType Specified.', 16, 1);

		RETURN -7;
	END;

	IF UPPER(@DatabasesToBackup) = N'[READ_FROM_FILESYSTEM]' BEGIN
		RAISERROR('@DatabasesToBackup may NOT be set to the token [READ_FROM_FILESYSTEM] when processing backups.', 16, 1);
		RETURN -9;
	END


-- TODO: I really need to validate retention details HERE... i.e., BEFORE we start running backups. 
--		not sure of the best way to do that - i.e., short of copy/paste of the logic (here and there).

-- honestly, probably makes the most sense to push validation into a scalar UDF. the UDF returns a string/error or NULL (if there's nothing wrong). That way, both sprocs can use the validation details easily. 

	--IF (DATEADD(MINUTE, 0 - @fileRetentionMinutes, GETDATE())) >= GETDATE() BEGIN 
	--	 RAISERROR('Invalid @BackupRetentionHours - greater than or equal to NOW.', 16, 1);
	--	 RETURN -10;
	--END;

	--IF NULLIF(@CopyToBackupDirectory, '') IS NOT NULL BEGIN
	--	IF (DATEADD(MINUTE, 0 - @copyToFileRetentionMinutes, GETDATE())) >= GETDATE() BEGIN
	--		RAISERROR('Invalid @CopyToBackupRetentionHours - greater than or equal to NOW.', 16, 1);
	--		RETURN -11;
	--	END;
	--END;

	IF NULLIF(@EncryptionCertName, '') IS NOT NULL BEGIN
		-- make sure the cert name is legit and that an encryption algorithm was specified:
		IF NOT EXISTS (SELECT NULL FROM master.sys.certificates WHERE name = @EncryptionCertName) BEGIN
			RAISERROR('Certificate name specified by @EncryptionCertName is not a valid certificate (not found in sys.certificates).', 16, 1);
			RETURN -15;
		END;

		IF NULLIF(@EncryptionAlgorithm, '') IS NULL BEGIN
			RAISERROR('@EncryptionAlgorithm must be specified when @EncryptionCertName is specified.', 16, 1);
			RETURN -15;
		END;
	END;

	-----------------------------------------------------------------------------
	-- Determine which databases to backup:
	DECLARE @executingSystemDbBackups bit = 0;

	IF UPPER(@DatabasesToBackup) = '[SYSTEM]' BEGIN
		SET @executingSystemDbBackups = 1;
	END; 

	DECLARE @serialized nvarchar(MAX);
	EXEC dbo.load_database_names
	    @Input = @DatabasesToBackup,
	    @Exclusions = @DatabasesToExclude,
		@Priorities = @Priorities,
	    @Mode = N'BACKUP',
	    @BackupType = @BackupType, 
		@Output = @serialized OUTPUT;

	DECLARE @targetDatabases table (
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [database_name] sysname NOT NULL
    ); 

	INSERT INTO @targetDatabases ([database_name])
	SELECT [result] FROM dbo.split_string(@serialized, N',');

	-- verify that we've got something: 
	IF (SELECT COUNT(*) FROM @targetDatabases) <= 0 BEGIN
		IF @AllowNonAccessibleSecondaries = 1 BEGIN
			-- Because we're dealing with Mirrored DBs, we won't fail or throw an error here. Instead, we'll just report success (with no DBs to backup).
			PRINT 'No ONLINE databases available for backup. BACKUP terminating with success.';
			RETURN 0;

		   END; 
		ELSE BEGIN
			PRINT 'Usage: @DatabasesToBackup = [SYSTEM]|[USER]|dbname1,dbname2,dbname3,etc';
			RAISERROR('No databases specified for backup.', 16, 1);
			RETURN -20;
		END;
	END;

	IF @BackupDirectory = @CopyToBackupDirectory BEGIN
		RAISERROR('@BackupDirectory and @CopyToBackupDirectory can NOT be the same directory.', 16, 1);
		RETURN - 50;
	END;

	-- normalize paths: 
	IF(RIGHT(@BackupDirectory, 1) = '\')
		SET @BackupDirectory = LEFT(@BackupDirectory, LEN(@BackupDirectory) - 1);

	IF(RIGHT(@CopyToBackupDirectory, 1) = '\')
		SET @CopyToBackupDirectory = LEFT(@CopyToBackupDirectory, LEN(@CopyToBackupDirectory) - 1);

	----------------------------------------------------------------------------------------------------------------------------------------------------------
	-----------------------------------------------------------------------------
	-- meta-data:
	DECLARE @executionID uniqueidentifier = NEWID();
	DECLARE @operationStart datetime;
	DECLARE @errorMessage nvarchar(MAX);
	DECLARE @copyMessage nvarchar(MAX);
	DECLARE @currentOperationID int;

	DECLARE @currentDatabase sysname;
	DECLARE @backupPath nvarchar(2000);
	DECLARE @copyToBackupPath nvarchar(2000);

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	DECLARE @serverName sysname;
	DECLARE @extension sysname;
	DECLARE @now datetime;
	DECLARE @timestamp sysname;
	DECLARE @offset sysname;
	DECLARE @backupName sysname;
	DECLARE @encryptionClause nvarchar(2000);
	DECLARE @copyStart datetime;
	DECLARE @outcome varchar(4000);

	DECLARE @command nvarchar(MAX);
	
	-- Begin the backups:
	DECLARE backups CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name] 
	FROM 
		@targetDatabases
	ORDER BY 
		[entry_id];

	OPEN backups;

	FETCH NEXT FROM backups INTO @currentDatabase;
	WHILE @@FETCH_STATUS = 0 BEGIN
		
		SET @errorMessage = NULL;
		SET @copyMessage = NULL;
		SET @outcome = NULL;
		SET @currentOperationID = NULL;

		-- start by making sure the current DB (which we grabbed during initialization) is STILL online/accessible (and hasn't failed over/etc.): 
		IF @currentDatabase IN (SELECT [name] FROM 
				(SELECT [name] FROM sys.databases WHERE UPPER(state_desc) != N'ONLINE' 
				 UNION SELECT [name] FROM sys.databases d INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id WHERE UPPER(hars.role_desc) != 'PRIMARY') x
		) BEGIN 
			PRINT 'Skipping database: ' + @currentDatabase + ' because it is no longer available, online, or accessible.';
			GOTO NextDatabase;  -- just 'continue' - i.e., short-circuit processing of this 'loop'... 
		END; 

		-- specify and verify path info:
		IF @executingSystemDbBackups = 1 AND @AddServerNameToSystemBackupPath = 1
			SET @serverName = N'\' + REPLACE(@@SERVERNAME, N'\', N'_'); -- account for named instances. 
		ELSE 
			SET @serverName = N'';

		SET @backupPath = @BackupDirectory + N'\' + @currentDatabase + @serverName;
		SET @copyToBackupPath = REPLACE(@backupPath, @BackupDirectory, @CopyToBackupDirectory); 

		SET @operationStart = GETDATE();
		IF (@LogSuccessfulOutcomes = 1) AND (@PrintOnly = 0)  BEGIN
			INSERT INTO dbo.backup_log (execution_id, backup_date, [database], backup_type, backup_path, copy_path, backup_start)
			VALUES(@executionID, GETDATE(), @currentDatabase, @BackupType, @backupPath, @copyToBackupPath, @operationStart);
			
			SELECT @currentOperationID = SCOPE_IDENTITY();
		END;

		IF @RemoveFilesBeforeBackup = 1 BEGIN
			GOTO RemoveOlderFiles;  -- zip down into the logic for removing files, then... once that's done... we'll get sent back up here (to DoneRemovingFilesBeforeBackup) to execute the backup... 

DoneRemovingFilesBeforeBackup:
		END

		SET @command = 'EXECUTE master.dbo.xp_create_subdir N''' + @backupPath + ''';';

		IF @PrintOnly = 1
			PRINT @command;
		ELSE BEGIN
			BEGIN TRY
				SET @outcome = NULL;
				EXEC dbo.execute_uncatchable_command @command, 'CREATEDIR', @result = @outcome OUTPUT;

				IF @outcome IS NOT NULL
					SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';

			END TRY
			BEGIN CATCH 
				SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected exception attempting to validate file path for backup: [' + @backupPath + N']. Error: [' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N']. Backup Filepath non-valid. Cannot continue with backup.';
			END CATCH;
		END;

		-- Normally, it wouldn't make sense to 'bail' on backups simply because we couldn't remove an older file. But, when the directive is to RemoveFilesBEFORE backups, we have to 'bail' to avoid running out of disk space when we can't delete files BEFORE backups. 
		IF @errorMessage IS NOT NULL
			GOTO NextDatabase;

		-- Create a Backup Name: 
		SET @extension = N'.bak';
		IF @BackupType = N'LOG'
			SET @extension = N'.trn';

		SET @now = GETDATE();
		SET @timestamp = REPLACE(REPLACE(REPLACE(CONVERT(sysname, @now, 120), '-','_'), ':',''), ' ', '_');
		SET @offset = RIGHT(CAST(CAST(RAND() AS decimal(12,11)) AS varchar(20)),7);

		SET @backupName = @BackupType + N'_' + @currentDatabase + '_backup_' + @timestamp + '_' + @offset + @extension;

		SET @command = N'BACKUP {type} ' + QUOTENAME(@currentDatabase, N'[]') + N' TO DISK = N''' + @backupPath + N'\' + @backupName + ''' 
	WITH 
		{COMPRESSION}{DIFFERENTIAL}{ENCRYPTION} NAME = N''' + @backupName + ''', SKIP, REWIND, NOUNLOAD, CHECKSUM;
	
	';

		IF @BackupType IN (N'FULL', N'DIFF')
			SET @command = REPLACE(@command, N'{type}', N'DATABASE');
		ELSE 
			SET @command = REPLACE(@command, N'{type}', N'LOG');

		IF @Edition IN (N'EXPRESS',N'WEB')
			SET @command = REPLACE(@command, N'{COMPRESSION}', N'');
		ELSE 
			SET @command = REPLACE(@command, N'{COMPRESSION}', N'COMPRESSION, ');

		IF @BackupType = N'DIFF'
			SET @command = REPLACE(@command, N'{DIFFERENTIAL}', N'DIFFERENTIAL, ');
		ELSE 
			SET @command = REPLACE(@command, N'{DIFFERENTIAL}', N'');

		IF NULLIF(@EncryptionCertName, '') IS NOT NULL BEGIN
			SET @encryptionClause = ' ENCRYPTION (ALGORITHM = ' + ISNULL(@EncryptionAlgorithm, N'AES_256') + N', SERVER CERTIFICATE = ' + ISNULL(@EncryptionCertName, '') + N'), ';
			SET @command = REPLACE(@command, N'{ENCRYPTION}', @encryptionClause);
		  END;
		ELSE 
			SET @command = REPLACE(@command, N'{ENCRYPTION}','');

		IF @PrintOnly = 1
			PRINT @command;
		ELSE BEGIN
			BEGIN TRY
				SET @outcome = NULL;
				EXEC dbo.execute_uncatchable_command @command, 'BACKUP', @result = @outcome OUTPUT;

				IF @outcome IS NOT NULL
					SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';
			END TRY
			BEGIN CATCH
				SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected Exception executing backup with the following command: [' + @command + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
			END CATCH;
		END;

		IF @errorMessage IS NOT NULL
			GOTO NextDatabase;

		IF @LogSuccessfulOutcomes = 1 BEGIN
			UPDATE dbo.backup_log 
			SET 
				backup_end = GETDATE(),
				backup_succeeded = 1, 
				verification_start = GETDATE()
			WHERE 
				backup_id = @currentOperationID;
		END;

		-----------------------------------------------------------------------------
		-- Kick off the verification:
		SET @command = N'RESTORE VERIFYONLY FROM DISK = N''' + @backupPath + N'\' + @backupName + N''' WITH NOUNLOAD, NOREWIND;';

		IF @PrintOnly = 1 
			PRINT @command;
		ELSE BEGIN
			BEGIN TRY
				EXEC sys.sp_executesql @command;

				IF @LogSuccessfulOutcomes = 1 BEGIN
					UPDATE dbo.backup_log
					SET 
						verification_end = GETDATE(),
						verification_succeeded = 1
					WHERE
						backup_id = @currentOperationID;
				END;
			END TRY
			BEGIN CATCH
				SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected exception during backup verification for backup of database: ' + @currentDatabase + '. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';

					UPDATE dbo.backup_log
					SET 
						verification_end = GETDATE(),
						verification_succeeded = 0,
						error_details = @errorMessage
					WHERE
						backup_id = @currentOperationID;

				GOTO NextDatabase;
			END CATCH;
		END;

		-----------------------------------------------------------------------------
		-- Now that the backup (and, optionally/ideally) verification are done, copy the file to a secondary location if specified:
		IF NULLIF(@CopyToBackupDirectory, '') IS NOT NULL BEGIN
			
			SET @copyStart = GETDATE();
			SET @command = 'EXECUTE master.dbo.xp_create_subdir N''' + @copyToBackupPath + ''';';

			IF @PrintOnly = 1 
				PRINT @command;
			ELSE BEGIN
				BEGIN TRY 
					SET @outcome = NULL;
					EXEC dbo.execute_uncatchable_command @command, 'CREATEDIR', @result = @outcome OUTPUT;
					
					IF @outcome IS NOT NULL
						SET @copyMessage = @outcome;
				END TRY
				BEGIN CATCH
					SET @copyMessage = N'Unexpected exception attempting to validate COPY_TO file path for backup: [' + @copyToBackupPath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N'. Detail: [' + ISNULL(@copyMessage, '') + N']';
				END CATCH;
			END;

			-- if we didn't run into validation errors, we can go ahead and try the copyTo process: 
			IF @copyMessage IS NULL BEGIN

				DECLARE @copyOutput TABLE ([output] nvarchar(2000));
				DELETE FROM @copyOutput;

				SET @command = 'EXEC xp_cmdshell ''COPY "' + @backupPath + N'\' + @backupName + '" "' + @copyToBackupPath + '\"''';

				IF @PrintOnly = 1
					PRINT @command;
				ELSE BEGIN
					BEGIN TRY

						INSERT INTO @copyOutput ([output])
						EXEC sys.sp_executesql @command;

						IF NOT EXISTS(SELECT NULL FROM @copyOutput WHERE [output] LIKE '%1 file(s) copied%') BEGIN; -- there was an error, and we didn't copy the file.
							SET @copyMessage = ISNULL(@copyMessage, '') + (SELECT TOP 1 [output] FROM @copyOutput WHERE [output] IS NOT NULL AND [output] NOT LIKE '%0 file(s) copied%') + N' ';
						END;

						IF @LogSuccessfulOutcomes = 1 BEGIN 
							UPDATE dbo.backup_log
							SET 
								copy_succeeded = 1,
								copy_seconds = DATEDIFF(SECOND, @copyStart, GETDATE()), 
								failed_copy_attempts = 0
							WHERE
								backup_id = @currentOperationID;
						END;
					END TRY
					BEGIN CATCH

						SET @copyMessage = ISNULL(@copyMessage, '') + N'Unexpected error copying backup to [' + @copyToBackupPath + @serverName + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
					END CATCH;
				END;
		    END;

			IF @copyMessage IS NOT NULL BEGIN

				IF @currentOperationId IS NULL BEGIN
					-- if we weren't logging successful operations, this operation isn't now a 100% failure, but there are problems, so we need to create a row for reporting/tracking purposes:
					INSERT INTO dbo.backup_log (execution_id, backup_date, [database], backup_type, backup_path, copy_path, backup_start, backup_end, backup_succeeded)
					VALUES (@executionID, GETDATE(), @currentDatabase, @BackupType, @backupPath, @copyToBackupPath, @operationStart, GETDATE(),0);

					SELECT @currentOperationID = SCOPE_IDENTITY();
				END

				UPDATE dbo.backup_log
				SET 
					copy_succeeded = 0, 
					copy_seconds = DATEDIFF(SECOND, @copyStart, GETDATE()), 
					failed_copy_attempts = 1, 
					copy_details = @copyMessage
				WHERE 
					backup_id = @currentOperationID;
			END;
		END;

		-----------------------------------------------------------------------------
		-- Remove backups:
		-- Branch into this logic either by means of a GOTO (called from above) or by means of evaluating @RemoveFilesBeforeBackup.... 
		IF @RemoveFilesBeforeBackup = 0 BEGIN;
			
RemoveOlderFiles:
			BEGIN TRY

				IF @PrintOnly = 1 BEGIN;
					PRINT '-- EXEC dbo.remove_backup_files @BackupType = ''' + @BackupType + ''', @DatabasesToProcess = ''' + @currentDatabase + ''', @TargetDirectory = ''' + @BackupDirectory + ''', @Retention = ''' + @BackupRetention + ''', @PrintOnly = 1;';
					
                    EXEC dbo.remove_backup_files
                        @BackupType= @BackupType,
                        @DatabasesToProcess = @currentDatabase,
                        @TargetDirectory = @BackupDirectory,
                        @Retention = @BackupRetention, 
						@OperatorName = @OperatorName,
						@MailProfileName  = @DatabaseMailProfile,

						-- note:
                        @PrintOnly = 1;

				  END;
				ELSE BEGIN;
					SET @outcome = 'OUTPUT';
					DECLARE @Output nvarchar(MAX);
					EXEC dbo.remove_backup_files
						@BackupType= @BackupType,
						@DatabasesToProcess = @currentDatabase,
						@TargetDirectory = @BackupDirectory,
						@Retention = @BackupRetention,
						@OperatorName = @OperatorName,
						@MailProfileName  = @DatabaseMailProfile, 
						@Output = @outcome OUTPUT;

					IF @outcome IS NOT NULL 
						SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + ' ';

				END

				IF NULLIF(@CopyToBackupDirectory,'') IS NOT NULL BEGIN;
				
					IF @PrintOnly = 1 BEGIN;
						PRINT '-- EXEC dbo.remove_backup_files @BackupType = ''' + @BackupType + ''', @DatabasesToProcess = ''' + @currentDatabase + ''', @TargetDirectory = ''' + @CopyToBackupDirectory + ''', @Retention = ''' + @CopyToRetention + ''', @PrintOnly = 1;';
						
						EXEC dbo.remove_backup_files
							@BackupType= @BackupType,
							@DatabasesToProcess = @currentDatabase,
							@TargetDirectory = @CopyToBackupDirectory,
							@Retention = @CopyToRetention, 
							@OperatorName = @OperatorName,
							@MailProfileName  = @DatabaseMailProfile,

							--note:
							@PrintOnly = 1;

					  END;
					ELSE BEGIN;
						SET @outcome = 'OUTPUT';
					
						EXEC dbo.remove_backup_files
							@BackupType= @BackupType,
							@DatabasesToProcess = @currentDatabase,
							@TargetDirectory = @CopyToBackupDirectory,
							@Retention = @CopyToRetention, 
							@OperatorName = @OperatorName,
							@MailProfileName  = @DatabaseMailProfile,
							@Output = @outcome OUTPUT;					
					
						IF @outcome IS NOT NULL
							SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';
					END
				END
			END TRY 
			BEGIN CATCH 
				SET @errorMessage = ISNULL(@errorMessage, '') + 'Unexpected Error removing backups. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
			END CATCH

			IF @RemoveFilesBeforeBackup = 1 BEGIN;
				IF @errorMessage IS NULL -- there weren't any problems/issues - so keep processing.
					GOTO DoneRemovingFilesBeforeBackup;

				-- otherwise, the remove operations failed, they were set to run FIRST, which means we now might not have enough disk - so we need to 'fail' this operation and move on to the next db... 
				GOTO NextDatabase;
			END
		END

NextDatabase:
		IF (SELECT CURSOR_STATUS('local','nuker')) > -1 BEGIN;
			CLOSE nuker;
			DEALLOCATE nuker;
		END;

		IF NULLIF(@errorMessage,'') IS NOT NULL BEGIN;
			IF @PrintOnly = 1 
				PRINT @errorMessage;
			ELSE BEGIN;
				IF @currentOperationId IS NULL BEGIN;
					INSERT INTO dbo.backup_log (execution_id, backup_date, [database], backup_type, backup_path, copy_path, backup_start, backup_end, backup_succeeded, error_details)
					VALUES (@executionID, GETDATE(), @currentDatabase, @BackupType, @backupPath, @copyToBackupPath, @operationStart, GETDATE(), 0, @errorMessage);
				  END;
				ELSE BEGIN;
					UPDATE dbo.backup_log
					SET 
						error_details = @errorMessage
					WHERE 
						backup_id = @currentOperationID;
				END;
			END;
		END; 

		PRINT '
';

		FETCH NEXT FROM backups INTO @currentDatabase;
	END;

	CLOSE backups;
	DEALLOCATE backups;

	----------------------------------------------------------------------------------------------------------------------------------------------------------
	-----------------------------------------------------------------------------
	-- Cleanup:

	-- close/deallocate any cursors left open:
	IF (SELECT CURSOR_STATUS('local','backups')) > -1 BEGIN;
		CLOSE backups;
		DEALLOCATE backups;
	END;


	-- MKC:
--			need to add some additional logic/processing here. 
--			a) look for failed copy operations up to X hours ago? 
--		    b) try to re-run them - via dba_sync... or ... via 'raw' roboopy? hmmm. 
--			c) mark any that succeed as done... success. 
--			d) up-tick any that still failed. 
--			e) for any that exceed @maxCopyToRetries - create an error and log it against all previous rows/databases that have failed? hmmm. Yeah... if we've been failing for, say, 45 minutes and sending 'warnings'... then we want to 
--				'call it' for all of the ones that have failed up to this point... and flag them as 'errored out' (might require a new column in the table). OR... maybe it works by me putting something like the following into error details
--				(for ALL rows that have failed up to this point - i.e., previous attempts + the current attempt/iteration):
--				"Attempts to copy backups from @sourcePath to @copyToPath consistently failed from @backupEndTime to @now (duration?) over @MaxSomethingAttempts. No longer attempting to synchronize files - meaning that backups are in jeopardy. Please
--					fix @CopyToPath and, when complete, run dba_syncDbs with such and such arguments? to ensure dbs copied on to secondary...."
--			   because, if that happens... then... the 'history' for backups will show errors (whereas they didn't show/report errors previously - so that covers 'history' - with a summary of when we 'called it'... 
--				and, this covers... the current rows as well. i.e., they'll have errors... which will then get picked up by the logic below. 
--			f) for any true 'errors', those get picked up below. 
--			g) for any non-errors - but failures to copy, there needs to be a 'warning' email sent - with a summary (list) of each db that hasn't copied - current number of attempts, how long it's been, etc. 



	DECLARE @emailErrorMessage nvarchar(MAX);

	IF EXISTS (SELECT NULL FROM dbo.backup_log WHERE execution_id = @executionID AND error_details IS NOT NULL) BEGIN;
		SET @emailErrorMessage = N'The following errors were encountered: ' + @crlf;

		SELECT @emailErrorMessage = @emailErrorMessage + @tab + N'- Target Database: [' + [database] + N']. Error: ' + error_details + @crlf + @crlf
		FROM 
			dbo.backup_log
		WHERE 
			execution_id = @executionID
			AND error_details IS NOT NULL 
		ORDER BY 
			backup_id;

	END;

	DECLARE @emailSubject nvarchar(2000);
	IF @emailErrorMessage IS NOT NULL BEGIN;
		
		SET @emailSubject = @EmailSubjectPrefix + N' - ERROR';
		
		IF @Edition != 'EXPRESS' BEGIN;
			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @emailSubject, 
				@body = @emailErrorMessage;
		END;

		-- make sure the sproc FAILS at this point (especially if this is a job). 
		SET @errorMessage = N'One or more operations failed. Execute [ SELECT * FROM [utility].dbo.backup_log WHERE execution_id = ''' + CAST(@executionID AS nvarchar(36)) + N'''; ] for details.';
		RAISERROR(@errorMessage, 16, 1);
		RETURN -100;
	END;

	RETURN 0;
GO



USE [admindb];
GO


IF OBJECT_ID('dbo.restore_databases','P') IS NOT NULL
	DROP PROC dbo.restore_databases;
GO

CREATE PROC dbo.restore_databases 
	@DatabasesToRestore				nvarchar(MAX),
	@DatabasesToExclude				nvarchar(MAX) = NULL,
	@Priorities						nvarchar(MAX) = NULL,
	@BackupsRootPath				nvarchar(MAX),
	@RestoredRootDataPath			nvarchar(MAX),
	@RestoredRootLogPath			nvarchar(MAX),
	@RestoredDbNamePattern			nvarchar(40) = N'{0}_test',
	@AllowReplace					nchar(7) = NULL,		-- NULL or the exact term: N'REPLACE'...
	@SkipLogBackups					bit = 0,
	@CheckConsistency				bit = 1,
	@DropDatabasesAfterRestore		bit = 0,				-- Only works if set to 1, and if we've RESTORED the db in question. 
	@MaxNumberOfFailedDrops			int = 1,				-- number of failed DROP operations we'll tolerate before early termination.
	@OperatorName					sysname = N'Alerts',
	@MailProfileName				sysname = N'General',
	@EmailSubjectPrefix				nvarchar(50) = N'[RESTORE TEST] ',
	@PrintOnly						bit = 0
AS
	SET NOCOUNT ON;

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	IF OBJECT_ID('dbo.restore_log', 'U') IS NULL BEGIN
		RAISERROR('S4 Table dbo.restore_log not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;
	
	IF OBJECT_ID('dbo.load_database_names', 'P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.load_database_names not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dbo.check_paths', 'P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.check_paths not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dbo.execute_uncatchable_command','P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.execute_uncatchable_command not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF EXISTS (SELECT NULL FROM sys.configurations WHERE name = 'xp_cmdshell' AND value_in_use = 0) BEGIN
		RAISERROR('xp_cmdshell is not currently enabled.', 16, 1);
		RETURN -1;
	END;

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF @PrintOnly = 0 BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 
		
		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -2;
		 END;
		ELSE BEGIN 
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
				RAISERROR('Invalild Operator Name Specified.', 16, 1);
				RETURN -2;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255)
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output'
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -2;
		END; 
	END;

	IF @MaxNumberOfFailedDrops <= 0 BEGIN
		RAISERROR('@MaxNumberOfFailedDrops must be set to a value of 1 or higher.', 16, 1);
		RETURN -6;
	END;

	IF NULLIF(@AllowReplace, '') IS NOT NULL AND UPPER(@AllowReplace) != N'REPLACE' BEGIN
		RAISERROR('The @AllowReplace switch must be set to NULL or the exact term N''REPLACE''.', 16, 1);
		RETURN -4;
	END;

	IF @AllowReplace IS NOT NULL AND @DropDatabasesAfterRestore = 1 BEGIN
		RAISERROR('Databases cannot be explicitly REPLACED and DROPPED after being replaced. If you wish DBs to be restored (on a different server for testing) with SAME names as PROD, simply leave suffix empty (but not NULL) and leave @AllowReplace NULL.', 16, 1);
		RETURN -6;
	END;

	IF UPPER(@DatabasesToRestore) IN (N'[SYSTEM]', N'[USER]') BEGIN
		RAISERROR('The tokens [SYSTEM] and [USER] cannot be used to specify which databases to restore via dba_RestoreDatabases. Use either [READ_FROM_FILESYSTEM] (plus any exclusions via @DatabasesToExclude), or specify a comma-delimited list of databases to restore.', 16, 1);
		RETURN -10;
	END;

	IF RTRIM(LTRIM(@DatabasesToExclude)) = N''
		SET @DatabasesToExclude = NULL;

	IF (@DatabasesToExclude IS NOT NULL) AND (UPPER(@DatabasesToRestore) != N'[READ_FROM_FILESYSTEM]') BEGIN
		RAISERROR('@DatabasesToExclude can ONLY be specified when @DatabasesToRestore is defined as the [READ_FROM_FILESYSTEM] token. Otherwise, if you don''t want a database restored, don''t specify it in the @DatabasesToRestore ''list''.', 16, 1);
		RETURN -20;
	END;

	IF (NULLIF(@RestoredDbNamePattern,'')) IS NULL BEGIN
		RAISERROR('@RestoredDbNamePattern can NOT be NULL or empty. It MAY also contain the place-holder token ''{0}'' to represent the name of the original database (e.g., ''{0}_test'' would become ''dbname_test'' when restoring a database named ''dbname'').', 16, 1);
		RETURN -22;
	END;

	-- 'Global' Variables:
	DECLARE @isValid bit;
	DECLARE @earlyTermination nvarchar(MAX) = N'';
	DECLARE @emailErrorMessage nvarchar(MAX);
	DECLARE @emailSubject nvarchar(300);
	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @tab char(1) = CHAR(9);
	DECLARE @executionID uniqueidentifier = NEWID();
	DECLARE @restoreSucceeded bit;
	DECLARE @failedDrops int = 0;

	-- Verify Paths: 
	EXEC dbo.check_paths @BackupsRootPath, @isValid OUTPUT;
	IF @isValid = 0 BEGIN;
		SET @earlyTermination = N'@BackupsRootPath (' + @BackupsRootPath + N') is invalid - restore operations terminated prematurely.';
		GOTO FINALIZE;
	END
	
	EXEC dbo.check_paths @RestoredRootDataPath, @isValid OUTPUT;
	IF @isValid = 0 BEGIN;
		SET @earlyTermination = N'@RestoredRootDataPath (' + @RestoredRootDataPath + N') is invalid - restore operations terminated prematurely.';
		GOTO FINALIZE;
	END

	EXEC dbo.check_paths @RestoredRootLogPath, @isValid OUTPUT;
	IF @isValid = 0 BEGIN;
		SET @earlyTermination = N'@RestoredRootLogPath (' + @RestoredRootLogPath + N') is invalid - restore operations terminated prematurely.';
		GOTO FINALIZE;
	END

	-----------------------------------------------------------------------------
	-- Construct list of databases to restore:
	DECLARE @serialized nvarchar(MAX);
	EXEC dbo.load_database_names
	    @Input = @DatabasesToRestore,         
	    @Exclusions = @DatabasesToExclude,		-- only works if [READ_FROM_FILESYSTEM] is specified for @Input... 
		@Priorities = @Priorities,
	    @Mode = N'RESTORE',
	    @TargetDirectory = @BackupsRootPath, 
		@Output = @serialized OUTPUT;

	DECLARE @dbsToRestore table (
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [database_name] sysname NOT NULL
    ); 

	INSERT INTO @dbsToRestore ([database_name])
	SELECT [result] FROM dbo.split_string(@serialized, N',');

	IF NOT EXISTS (SELECT NULL FROM @dbsToRestore) BEGIN;
		RAISERROR('No Databases Specified to Restore. Please Check inputs for @DatabasesToRestore + @DatabasesToExclude and retry.', 16, 1);
		RETURN -20;
	END

	IF @PrintOnly = 1 BEGIN;
		PRINT '-- Databases To Attempt Restore Against: ' + @serialized;
	END

	DECLARE restorer CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name]
	FROM 
		@dbsToRestore
	WHERE
		LEN([database_name]) > 0
	ORDER BY 
		entry_id;

	DECLARE @databaseToRestore sysname;
	DECLARE @restoredName sysname;

	DECLARE @fullRestoreTemplate nvarchar(MAX) = N'RESTORE DATABASE [{0}] FROM DISK = N''{1}'' WITH {move},{replace} NORECOVERY;'; 
	DECLARE @move nvarchar(MAX);
	DECLARE @restoreLogId int;
	DECLARE @sourcePath nvarchar(500);
	DECLARE @statusDetail nvarchar(500);
	DECLARE @pathToDatabaseBackup nvarchar(600);
	DECLARE @outcome varchar(4000);

	DECLARE @temp TABLE (
		[id] int IDENTITY(1,1), 
		[output] varchar(500)
	);

	-- Assemble a list of dbs (if any) that were NOT dropped during the last execution (only) - so that we can drop them before proceeding. 
	DECLARE @NonDroppedFromPreviousExecution table( 
		[Database] sysname NOT NULL, 
		RestoredAs sysname NOT NULL
	);

	DECLARE @LatestBatch uniqueidentifier;
	SELECT @LatestBatch = (SELECT TOP 1 execution_id FROM dbo.restore_log ORDER BY restore_test_id DESC);

	INSERT INTO @NonDroppedFromPreviousExecution ([Database], RestoredAs)
	SELECT [database], [restored_as]
	FROM dbo.restore_log 
	WHERE execution_id = @LatestBatch
		AND [dropped] = 'NOT-DROPPED'
		AND [restored_as] IN (SELECT name FROM sys.databases WHERE UPPER(state_desc) = 'RESTORING');  -- make sure we're only targeting DBs in the 'restoring' state too. 

	IF @CheckConsistency = 1 BEGIN
		IF OBJECT_ID('tempdb..##DBCC_OUTPUT') IS NOT NULL 
			DROP TABLE ##DBCC_OUTPUT;

		CREATE TABLE ##DBCC_OUTPUT(
				RowID int IDENTITY(1,1) NOT NULL, 
				Error int NULL,
				[Level] int NULL,
				[State] int NULL,
				MessageText nvarchar(2048) NULL,
				RepairLevel nvarchar(22) NULL,
				[Status] int NULL,
				[DbId] int NULL, -- was smallint in SQL2005
				DbFragId int NULL,      -- new in SQL2012
				ObjectId int NULL,
				IndexId int NULL,
				PartitionId bigint NULL,
				AllocUnitId bigint NULL,
				RidDbId smallint NULL,  -- new in SQL2012
				RidPruId smallint NULL, -- new in SQL2012
				[File] smallint NULL,
				[Page] int NULL,
				Slot int NULL,
				RefDbId smallint NULL,  -- new in SQL2012
				RefPruId smallint NULL, -- new in SQL2012
				RefFile smallint NULL,
				RefPage int NULL,
				RefSlot int NULL,
				Allocation smallint NULL
		);
	END

	CREATE TABLE #FileList (
		LogicalName nvarchar(128) NOT NULL, 
		PhysicalName nvarchar(260) NOT NULL,
		[Type] CHAR(1) NOT NULL, 
		FileGroupName nvarchar(128) NULL, 
		Size numeric(20,0) NOT NULL, 
		MaxSize numeric(20,0) NOT NULL, 
		FileID bigint NOT NULL, 
		CreateLSN numeric(25,0) NOT NULL, 
		DropLSN numeric(25,0) NULL, 
		UniqueId uniqueidentifier NOT NULL, 
		ReadOnlyLSN numeric(25,0) NULL, 
		ReadWriteLSN numeric(25,0) NULL, 
		BackupSizeInBytes bigint NOT NULL, 
		SourceBlockSize int NOT NULL, 
		FileGroupId int NOT NULL, 
		LogGroupGUID uniqueidentifier NULL, 
		DifferentialBaseLSN numeric(25,0) NULL, 
		DifferentialBaseGUID uniqueidentifier NOT NULL, 
		IsReadOnly bit NOT NULL, 
		IsPresent bit NOT NULL, 
		TDEThumbprint varbinary(32) NULL
	);

	-- SQL Server 2016 adds SnapshotURL of nvarchar(360) for azure stuff:
	IF EXISTS (SELECT NULL FROM (SELECT SERVERPROPERTY('ProductMajorVersion') AS [ProductMajorVersion]) x WHERE x.ProductMajorVersion = '13') BEGIN;
		ALTER TABLE #FileList ADD SnapshotURL nvarchar(360) NULL;
	END

	DECLARE @command nvarchar(2000);

	OPEN restorer;

	FETCH NEXT FROM restorer INTO @databaseToRestore;
	WHILE @@FETCH_STATUS = 0 BEGIN;
		
		SET @statusDetail = NULL; -- reset every 'loop' through... 
		SET @restoredName = REPLACE(@RestoredDbNamePattern, N'{0}', @databaseToRestore);
		IF (@restoredName = @databaseToRestore) AND (@RestoredDbNamePattern != '{0}') -- then there wasn't a {0} token - so set @restoredName to @RestoredDbNamePattern
			SET @restoredName = @RestoredDbNamePattern;  -- which seems odd, but if they specified @RestoredDbNamePattern = 'Production2', then that's THE name they want...

		IF @PrintOnly = 0 BEGIN;
			INSERT INTO dbo.restore_log (execution_id, [database], restored_as, restore_start, error_details)
			VALUES (@executionID, @databaseToRestore, @restoredName, GETUTCDATE(), '#UNKNOWN ERROR#');

			SELECT @restoreLogId = SCOPE_IDENTITY();
		END

		-- Verify Path to Source db's backups:
		SET @sourcePath = @BackupsRootPath + N'\' + @databaseToRestore;
		EXEC dbo.check_paths @sourcePath, @isValid OUTPUT;
		IF @isValid = 0 BEGIN 
			SET @statusDetail = N'The backup path: ' + @sourcePath + ' is invalid;';
			GOTO NextDatabase;
		END

		-- Determine how to respond to an attempt to overwrite an existing database (i.e., is it explicitly confirmed or... should we throw an exception).
		IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = @restoredName) BEGIN;
			
			-- if this is a 'failure' from a previous execution, drop the DB and move on, otherwise, make sure we are explicitly configured to REPLACE. 
			IF EXISTS (SELECT NULL FROM @NonDroppedFromPreviousExecution WHERE [Database] = @databaseToRestore AND RestoredAs = @restoredName) BEGIN;
				SET @command = N'DROP DATABASE [' + @restoredName + N'];';
				
				EXEC dbo.execute_uncatchable_command @command, 'DROP', @result = @outcome OUTPUT;
				SET @statusDetail = @outcome;

				IF @statusDetail IS NOT NULL BEGIN;
					GOTO NextDatabase;
				END
			  END
			ELSE BEGIN;
				IF ISNULL(@AllowReplace, '') != N'REPLACE' BEGIN;
					SET @statusDetail = N'Cannot restore database [' + @databaseToRestore + N'] as [' + @restoredName + N'] - because target database already exists. Consult documentation for WARNINGS and options for using @AllowReplace parameter.';
					GOTO NextDatabase;
				END
			END
		END

		-- Enumerate the files and ensure we've got backups:
		SET @command = N'dir "' + @sourcePath + N'\" /B /A-D /OD';

		IF @PrintOnly = 1 BEGIN;
			PRINT N'-- xp_cmdshell ''' + @command + ''';';
		END
		
		INSERT INTO @temp ([output])
		EXEC master..xp_cmdshell @command;
		DELETE FROM @temp WHERE [output] IS NULL AND [output] NOT LIKE '%' + @databaseToRestore + '%';  -- remove 'empty' entries and any backups for databases OTHER than target.

		IF NOT EXISTS (SELECT NULL FROM @temp WHERE [output] LIKE 'FULL%') BEGIN 
			IF EXISTS (SELECT NULL FROM @temp WHERE [output] LIKE '%access%denied%') 
				SET @statusDetail = N'Access to path "' + @sourcePath + N'" is denied.';
			ELSE 
				SET @statusDetail = N'No FULL backups found for database [' + @databaseToRestore + N'] found in "' + @sourcePath + N'".';
			
			GOTO NextDatabase;	
		END

		-- Find the most recent FULL to 'seed' the restore;
		DELETE FROM @temp WHERE id < (SELECT MAX(id) FROM @temp WHERE [output] LIKE 'FULL%');
		SELECT @pathToDatabaseBackup = @sourcePath + N'\' + [output] FROM @temp WHERE [output] LIKE 'FULL%';

		IF @PrintOnly = 1 BEGIN;
			PRINT N'-- FULL Backup found at: ' + @pathToDatabaseBackup;
		END

		-- Query file destinations:
		SET @move = N'';
		SET @command = N'RESTORE FILELISTONLY FROM DISK = N''' + @pathToDatabaseBackup + ''';';

		IF @PrintOnly = 1 BEGIN;
			PRINT N'-- ' + @command;
		END

		BEGIN TRY 
			DELETE FROM #FileList;
			INSERT INTO #FileList -- shorthand syntax is usually bad, but... whatever. 
			EXEC sys.sp_executesql @command;
		END TRY
		BEGIN CATCH
			SELECT @statusDetail = N'Unexpected Error Restoring FileList: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
			
			GOTO NextDatabase;
		END CATCH
	
		-- Make sure we got some files (i.e. RESTORE FILELIST doesn't always throw exceptions if the path you send it sucks:
		IF ((SELECT COUNT(*) FROM #FileList) < 2) BEGIN;
			SET @statusDetail = N'The backup located at "' + @pathToDatabaseBackup + N'" is invalid, corrupt, or does not contain a viable FULL backup.';
			
			GOTO NextDatabase;
		END 
		
		-- Map File Destinations:
		DECLARE @LogicalFileName sysname, @FileId bigint, @Type char(1);
		DECLARE mover CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			LogicalName, FileID, [Type]
		FROM 
			#FileList
		ORDER BY 
			FileID;

		OPEN mover; 
		FETCH NEXT FROM mover INTO @LogicalFileName, @FileId, @Type;

		WHILE @@FETCH_STATUS = 0 BEGIN 

			SET @move = @move + N'MOVE ''' + @LogicalFileName + N''' TO ''' + CASE WHEN @FileId = 2 THEN @RestoredRootLogPath ELSE @RestoredRootDataPath END + N'\' + @restoredName + '.';
			IF @FileId = 1
				SET @move = @move + N'mdf';
			IF @FileId = 2
				SET @move = @move + N'ldf';
			IF @FileId NOT IN (1, 2)
				SET @move = @move + N'ndf';

			SET @move = @move + N''', '

			FETCH NEXT FROM mover INTO @LogicalFileName, @FileId, @Type;
		END

		CLOSE mover;
		DEALLOCATE mover;

		SET @move = LEFT(@move, LEN(@move) - 1); -- remove the trailing ", "... 

		-- IF we're going to allow an explicit REPLACE, start by putting the target DB into SINGLE_USER mode: 
		IF @AllowReplace = N'REPLACE' BEGIN;
			
			-- only attempt to set to single-user mode if ONLINE (i.e., if somehow stuck in restoring... don't bother, just replace):
			IF EXISTS(SELECT NULL FROM sys.databases WHERE name = @restoredName AND state_desc = 'ONLINE') BEGIN;

				BEGIN TRY 
					SET @command = N'ALTER DATABASE ' + QUOTENAME(@restoredName, N'[]') + ' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;';

					IF @PrintOnly = 1 BEGIN;
						PRINT @command;
					  END
					ELSE BEGIN
						SET @outcome = NULL;
						EXEC dbo.execute_uncatchable_command @command, 'ALTER', @result = @outcome OUTPUT;
						SET @statusDetail = @outcome;
					END

					-- give things just a second to 'die down':
					WAITFOR DELAY '00:00:02';

				END TRY
				BEGIN CATCH
					SELECT @statusDetail = N'Unexpected Exception while setting target database: "' + @restoredName + N'" into SINGLE_USER mode to allow explicit REPLACE operation. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
				END CATCH

				IF @statusDetail IS NOT NULL
				GOTO NextDatabase;
			END
		END

		-- Set up the Restore Command and Execute:
		SET @command = REPLACE(@fullRestoreTemplate, N'{0}', @restoredName);
		SET @command = REPLACE(@command, N'{1}', @pathToDatabaseBackup);
		SET @command = REPLACE(@command, N'{move}', @move);

		-- Otherwise, address the REPLACE command in our RESTORE @command: 
		IF @AllowReplace = N'REPLACE'
			SET @command = REPLACE(@command, N'{replace}', N' REPLACE, ');
		ELSE 
			SET @command = REPLACE(@command, N'{replace}',  N'');

		BEGIN TRY 
			IF @PrintOnly = 1 BEGIN;
				PRINT @command;
			  END
			ELSE BEGIN;
				SET @outcome = NULL;
				EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;

				SET @statusDetail = @outcome;
			END
		END TRY 
		BEGIN CATCH
			SELECT @statusDetail = N'Unexpected Exception while executing FULL Restore from File: "' + @pathToDatabaseBackup + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();			
		END CATCH

		IF @statusDetail IS NOT NULL BEGIN;
			GOTO NextDatabase;
		END

		-- Restore any DIFF backups as needed:
		IF EXISTS (SELECT NULL FROM @temp WHERE [output] LIKE 'DIFF%') BEGIN;
			DELETE FROM @temp WHERE id < (SELECT MAX(id) FROM @temp WHERE [output] LIKE N'DIFF%');

			SELECT @pathToDatabaseBackup = @sourcePath + N'\' + [output] FROM @temp WHERE [output] LIKE 'DIFF%';

			SET @command = N'RESTORE DATABASE ' + QUOTENAME(@restoredName, N'[]') + N' FROM DISK = N''' + @pathToDatabaseBackup + N''' WITH NORECOVERY;';

			BEGIN TRY
				IF @PrintOnly = 1 BEGIN;
					PRINT @command;
				  END
				ELSE BEGIN;
					SET @outcome = NULL;
					EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;

					SET @statusDetail = @outcome;
				END
			END TRY
			BEGIN CATCH
				SELECT @statusDetail = N'Unexpected Exception while executing DIFF Restore from File: "' + @pathToDatabaseBackup + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
			END CATCH

			IF @statusDetail IS NOT NULL BEGIN;
				GOTO NextDatabase;
			END
		END

		-- Restore any LOG backups if specified and if present:
		IF @SkipLogBackups = 0 BEGIN;
			DECLARE logger CURSOR LOCAL FAST_FORWARD FOR 
			SELECT [output] FROM @temp WHERE [output] LIKE 'LOG%' ORDER BY id ASC;			

			OPEN logger;
			FETCH NEXT FROM logger INTO @pathToDatabaseBackup;

			WHILE @@FETCH_STATUS = 0 BEGIN;
				SET @command = N'RESTORE LOG ' + QUOTENAME(@restoredName, N'[]') + N' FROM DISK = N''' + @sourcePath + N'\' + @pathToDatabaseBackup + N''' WITH NORECOVERY;';
				
				BEGIN TRY 
					IF @PrintOnly = 1 BEGIN;
						PRINT @command;
					  END
					ELSE BEGIN;
						SET @outcome = NULL;
						EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;

						SET @statusDetail = @outcome;
					END
				END TRY
				BEGIN CATCH
					SELECT @statusDetail = N'Unexpected Exception while executing LOG Restore from File: "' + @pathToDatabaseBackup + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

					-- this has to be closed/deallocated - or we'll run into it on the 'next' database/pass.
					IF (SELECT CURSOR_STATUS('local','logger')) > -1 BEGIN;
						CLOSE logger;
						DEALLOCATE logger;
					END
					
				END CATCH

				IF @statusDetail IS NOT NULL BEGIN;
					GOTO NextDatabase;
				END

				FETCH NEXT FROM logger INTO @pathToDatabaseBackup;
			END

			CLOSE logger;
			DEALLOCATE logger;
		END

		-- Recover the database:
		SET @command = N'RESTORE DATABASE ' + QUOTENAME(@restoredName, N'[]') + N' WITH RECOVERY;';

		BEGIN TRY
			IF @PrintOnly = 1 BEGIN;
				PRINT @command;
			  END
			ELSE BEGIN
				SET @outcome = NULL;
				EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;

				SET @statusDetail = @outcome;
			END;
		END TRY	
		BEGIN CATCH
			SELECT @statusDetail = N'Unexpected Exception while attempting to RECOVER database [' + @restoredName + N'. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
		END CATCH

		IF @statusDetail IS NOT NULL BEGIN;
			GOTO NextDatabase;
		END

		-- If we've made it here, then we need to update logging/meta-data:
		IF @PrintOnly = 0 BEGIN;
			UPDATE dbo.restore_log 
			SET 
				restore_succeeded = 1, 
				restore_end = GETUTCDATE(), 
				error_details = NULL
			WHERE 
				restore_test_id = @restoreLogId;
		END

		-- Run consistency checks if specified:
		IF @CheckConsistency = 1 BEGIN;

			SET @command = N'DBCC CHECKDB([' + @restoredName + N']) WITH NO_INFOMSGS, ALL_ERRORMSGS, TABLERESULTS;'; -- outputting data for review/analysis. 

			IF @PrintOnly = 0 BEGIN 
				UPDATE dbo.restore_log
				SET 
					consistency_start = GETUTCDATE(),
					consistency_succeeded = 0, 
					error_details = '#UNKNOWN ERROR CHECKING CONSISTENCY#'
				WHERE
					restore_test_id = @restoreLogId;
			END

			BEGIN TRY 
				IF @PrintOnly = 1 
					PRINT @command;
				ELSE BEGIN 
					DELETE FROM ##DBCC_OUTPUT;
					INSERT INTO ##DBCC_OUTPUT (Error, [Level], [State], MessageText, RepairLevel, [Status], [DbId], DbFragId, ObjectId, IndexId, PartitionId, AllocUnitId, RidDbId, RidPruId, [File], [Page], Slot, RefDbId, RefPruId, RefFile, RefPage, RefSlot, Allocation)
					EXEC sp_executesql @command; 

					IF EXISTS (SELECT NULL FROM ##DBCC_OUTPUT) BEGIN; -- consistency errors: 
						SET @statusDetail = N'CONSISTENCY ERRORS DETECTED against database ' + QUOTENAME(@restoredName, N'[]') + N'. Details: ' + @crlf;
						SELECT @statusDetail = @statusDetail + MessageText + @crlf FROM ##DBCC_OUTPUT ORDER BY RowID;

						UPDATE dbo.restore_log
						SET 
							consistency_end = GETUTCDATE(),
							consistency_succeeded = 0,
							error_details = @statusDetail
						WHERE 
							restore_test_id = @restoreLogId;

					  END
					ELSE BEGIN; -- there were NO errors:
						UPDATE dbo.restore_log
						SET
							consistency_end = GETUTCDATE(),
							consistency_succeeded = 1, 
							error_details = NULL
						WHERE 
							restore_test_id = @restoreLogId;

					END
				END

			END TRY	
			BEGIN CATCH
				SELECT @statusDetail = N'Unexpected Exception while running consistency checks. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
				GOTO NextDatabase;
			END CATCH

		END

		-- Drop the database if specified and if all SAFE drop precautions apply:
		IF @DropDatabasesAfterRestore = 1 BEGIN;
			
			-- Make sure we can/will ONLY restore databases that we've restored in this session. 
			SELECT @restoreSucceeded = restore_succeeded FROM dbo.restore_log WHERE restored_as = @restoredName AND execution_id = @executionID;

			IF @PrintOnly = 1 AND @DropDatabasesAfterRestore = 1
				SET @restoreSucceeded = 1; 
			
			IF ISNULL(@restoreSucceeded, 0) = 0 BEGIN 
				-- We can't drop this database.
				SET @failedDrops = @failedDrops + 1;

				UPDATE dbo.restore_log
				SET 
					[dropped] = 'ERROR', 
					error_details = error_details + @crlf + '(NOTE: DROP was configured but SKIPPED due to ERROR state.)'
				WHERE 
					restore_test_id = @restoreLogId;

				GOTO NextDatabase;
			END

			IF @restoreSucceeded = 1 BEGIN; -- this is a db we restored in this 'session' - so we can drop it:
				SET @command = N'DROP DATABASE ' + QUOTENAME(@restoredName, N'[]') + N';';

				BEGIN TRY 
					IF @PrintOnly = 1 
						PRINT @command;
					ELSE BEGIN;
						UPDATE dbo.restore_log 
						SET 
							[dropped] = N'ATTEMPTED'
						WHERE 
							restore_test_id = @restoreLogId;

						EXEC sys.sp_executesql @command;

						IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = @restoredName) BEGIN;
							SET @failedDrops = @failedDrops;
							SET @statusDetail = N'Executed command to DROP database [' + @restoredName + N']. No exceptions encountered, but database still in place POST-DROP.';

							GOTO NextDatabase;
						  END
						ELSE 
							UPDATE dbo.restore_log
							SET 
								dropped = 'DROPPED'
							WHERE 
								restore_test_id = @restoreLogId;
					END

				END TRY 
				BEGIN CATCH
					SELECT @statusDetail = N'Unexpected Exception while attempting to DROP database [' + @restoredName + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
					SET @failedDrops = @failedDrops + 1;

					UPDATE dbo.restore_log
					SET 
						dropped = 'ERROR'
					WHERE 
						restore_test_id = @restoredName;

					GOTO NextDatabase;
				END CATCH
			END

		  END
		ELSE BEGIN;
			UPDATE dbo.restore_log 
			SET 
				dropped = 'NOT-DROPPED'
			WHERE
				restore_test_id = @restoreLogId;
		END

		PRINT N'-- Operations for database [' + @restoredName + N'] completed successfully.' + @crlf + @crlf;

		-- If we made this this far, there have been no errors... and we can drop through into processing the next database... 
NextDatabase:

		DELETE FROM @temp; -- always make sure to clear the list of files handled for the previous database... 

		-- Record any status details as needed:
		IF @statusDetail IS NOT NULL BEGIN;

			IF @PrintOnly = 1 BEGIN;
				PRINT N'ERROR: ' + @statusDetail;
			  END
			ELSE BEGIN;
				UPDATE dbo.restore_log
				SET 
					restore_end = GETUTCDATE(),
					error_details = @statusDetail
				WHERE 
					restore_test_id = @restoreLogId;
			END

			PRINT N'-- Operations for database [' + @restoredName + N'] failed.' + @crlf + @crlf;
		END

		-- Check-up on total number of 'failed drops':
		IF @failedDrops >= @MaxNumberOfFailedDrops BEGIN;
			-- we're done - no more processing (don't want to risk running out of space with too many restore operations.
			SET @earlyTermination = N'Max number of databases that could NOT be dropped after restore/testing was reached. Early terminatation forced to reduce risk of causing storage problems.';
			GOTO FINALIZE;
		END

		FETCH NEXT FROM restorer INTO @databaseToRestore;
	END

	-----------------------------------------------------------------------------
FINALIZE:

	-- close/deallocate any cursors left open:
	IF (SELECT CURSOR_STATUS('local','restorer')) > -1 BEGIN;
		CLOSE restorer;
		DEALLOCATE restorer;
	END

	IF (SELECT CURSOR_STATUS('local','mover')) > -1 BEGIN;
		CLOSE mover;
		DEALLOCATE mover;
	END

	IF (SELECT CURSOR_STATUS('local','logger')) > -1 BEGIN;
		CLOSE logger;
		DEALLOCATE logger;
	END

	-- Assemble details on errors - if there were any (i.e., logged errors OR any reason for early termination... 
	IF (NULLIF(@earlyTermination,'') IS NOT NULL) OR (EXISTS (SELECT NULL FROM dbo.restore_log WHERE execution_id = @executionID AND error_details IS NOT NULL)) BEGIN;

		SET @emailErrorMessage = N'The following Errors were encountered: ' + @crlf;

		SELECT @emailErrorMessage = @emailErrorMessage + @tab + N'- Source Database: [' + [database] + N']. Attempted to Restore As: [' + restored_as + N']. Error: ' + error_details + @crlf + @crlf
		FROM 
			dbo.restore_log
		WHERE 
			execution_id = @executionID
			AND error_details IS NOT NULL
		ORDER BY 
			restore_test_id;

		-- notify too that we stopped execution due to early termination:
		IF NULLIF(@earlyTermination, '') IS NOT NULL BEGIN;
			SET @emailErrorMessage = @emailErrorMessage + @tab + N'- ' + @earlyTermination;
		END
	END
	
	IF @emailErrorMessage IS NOT NULL BEGIN;

		IF @PrintOnly = 1
			PRINT N'ERROR: ' + @emailErrorMessage;
		ELSE BEGIN;
			SET @emailSubject = @emailSubjectPrefix + N' - ERROR';

			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @emailSubject, 
				@body = @emailErrorMessage;
		END
	END 

	RETURN 0;
GO

PRINT 'done';