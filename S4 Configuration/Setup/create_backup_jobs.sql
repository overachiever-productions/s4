/*
		
	

	
*/

USE [admindb];
GO

IF OBJECT_ID('dbo.create_backup_jobs','P') IS NOT NULL
	DROP PROC dbo.[create_backup_jobs];
GO

CREATE PROC dbo.[create_backup_jobs]
	@FullAndLogUserDBTargets					sysname					= N'{USER}',
	@FullAndLogUserDBExclusions					sysname					= N'',
	@EncryptionCertName							sysname					= NULL,
	@BackupsDirectory							sysname					= N'{DEFAULT}', 
	@CopyToBackupDirectory						sysname					= N'',
	@SystemBackupRetention						sysname					= N'3 days', 
	@CopyToSystemBackupRetention				sysname					= N'3 days', 
	@UserFullBackupRetention					sysname					= N'3 days', 
	@CopyToUserFullBackupRetention				sysname					= N'3 days',
	@LogBackupRetention							sysname					= N'73 hours', 
	@CopyToLogBackupRetention					sysname					= N'73 hours',
	@AllowForSecondaryServers					bit						= 0,				-- Set to 1 for Mirrored/AG'd databases. 
	@FullSystemBackupsStartTime					sysname					= N'18:50:00',		-- if '', then system backups won't be created... 
	@FullUserBackupsStartTime					sysname					= N'00:02:00',		-- hmm... does it even make sense to let this be empty/null-ish? 
	@LogBackupsStartTime						sysname					= N'00:12:00',		-- ditto ish
	@LogBackupsRunEvery							sysname					= N'10 minutes',	-- vector, but only allows minutes (i think).
	@JobsNamePrefix								sysname					= N'Database Backups - ',		-- e.g., "Database Backups - USER - FULL" or "Database Backups - USER - LOG" or "Database Backups - SYSTEM - FULL"
	@JobsCategoryName							sysname					= N'Backups',							
	@JobOperatorToAlertOnErrors					sysname					= N'Alerts',	
	@ProfileToUseForAlerts						sysname					= N'General',
	@OverWriteExistingJobs						bit						= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}

	DECLARE @systemStart time, @userStart time, @logStart time;
	SELECT 
		@systemStart	= CAST(@FullSystemBackupsStartTime AS time), 
		@userStart		= CAST(@FullUserBackupsStartTime AS time), 
		@logStart		= CAST(@LogBackupsStartTime AS time);

	-- Verify minutes-only for T-Log Backups: 
	IF @logStart IS NOT NULL AND @LogBackupsRunEvery IS NOT NULL BEGIN 
		IF @LogBackupsRunEvery NOT LIKE '%minute%' BEGIN 
			RAISERROR('@LogBackupsRunEvery can only specify values defined in minutes - e.g., N''5 minutes'', or N''10 minutes'', etc.', 16, 1);
			RETURN -2;
		END;
	END;

	DECLARE @frequencyMinutes int;
	DECLARE @outcome int; 
	DECLARE @error nvarchar(MAX);

	EXEC @outcome = dbo.[translate_vector]
		@Vector = @LogBackupsRunEvery,
		@ValidationParameterName = N'@LogBackupsRunEvery',
		@ProhibitedIntervals = N'MILLISECOND,SECOND,HOUR,DAY,WEEK,MONTH,YEAR',
		@TranslationDatePart = 'MINUTE',
		@Output = @frequencyMinutes OUTPUT,
		@Error = @error OUTPUT;

	IF @outcome <> 0 BEGIN 
		RAISERROR(@error, 16, 1); 
		RETURN @outcome;
	END;

	DECLARE @backupsTemplate nvarchar(MAX) = N'EXEC admindb.dbo.[backup_databases]
	@BackupType = N''{backupType}'',
	@DatabasesToBackup = N''{targets}'',{exclusions}
	@BackupDirectory = N''{backupsDirectory}'',{copyToDirectory}
	@BackupRetention = N''{retention}'',{copyToRetention}{encryption}{secondaries}{operator}{profile}
	@PrintOnly = 0;';

	DECLARE @sysBackups nvarchar(MAX), @userBackups nvarchar(MAX), @logBackups nvarchar(MAX);
	DECLARE @crlfTab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);

	-- 'global' template config settings/options: 
	SET @backupsTemplate = REPLACE(@backupsTemplate, N'{backupsDirectory}', @BackupsDirectory);
	
	IF NULLIF(@EncryptionCertName, N'') IS NULL 
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{encryption}', N'');
	ELSE 
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{encryption}', @crlfTab + N'@EncryptionCertName = N''' + @EncryptionCertName + N''',' + @crlfTab + N'@EncryptionAlgorithm = N''AES_256'',');

	IF NULLIF(@CopyToBackupDirectory, N'') IS NULL BEGIN
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{copyToDirectory}', N'');
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{copyToRetention}', N'');
	  END;
	ELSE BEGIN
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{copyToDirectory}', @crlfTab + N'@CopyToBackupDirectory = N''' + @CopyToBackupDirectory + N''', ');
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{copyToRetention}', @crlfTab + N'@CopyToRetention = N''{copyRetention}'', ');
	END;

	IF NULLIF(@JobOperatorToAlertOnErrors, N'') IS NULL
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{operator}', N'');
	ELSE 
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{operator}', @crlfTab + N'@OperatorName = N''' + @JobOperatorToAlertOnErrors + N''', ');

	IF NULLIF(@ProfileToUseForAlerts, N'') IS NULL
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{profile}', N'');
	ELSE 
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{profile}', @crlfTab + N'@MailProfileName = N''' + @ProfileToUseForAlerts + N''', ');

	-- system backups: 
	SET @sysBackups = REPLACE(@backupsTemplate, N'{exclusions}', N'');

	IF @AllowForSecondaryServers = 0 
		SET @sysBackups = REPLACE(@sysBackups, N'{secondaries}', N'');
	ELSE 
		SET @sysBackups = REPLACE(@sysBackups, N'{secondaries}', @crlfTab + N'@AddServerNameToSystemBackupPath = 1, ');

	SET @sysBackups = REPLACE(@sysBackups, N'{backupType}', N'FULL');
	SET @sysBackups = REPLACE(@sysBackups, N'{targets}', N'{SYSTEM}');
	SET @sysBackups = REPLACE(@sysBackups, N'{retention}', @SystemBackupRetention);
	SET @sysBackups = REPLACE(@sysBackups, N'{copyRetention}', ISNULL(@CopyToSystemBackupRetention, N''));

	-- user backups (exclusions): 
	IF NULLIF(@FullAndLogUserDBExclusions, N'') IS NULL 
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{exclusions}', N'');
	ELSE 
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{exclusions}', @crlfTab + N'@DatabasesToExclude = N''{exclusions}'', ');

	-- full user backups: 
	SET @userBackups = @backupsTemplate;

	IF @AllowForSecondaryServers = 0 
		SET @userBackups = REPLACE(@userBackups, N'{secondaries}', N'');
	ELSE 
		SET @userBackups = REPLACE(@userBackups, N'{secondaries}', @crlfTab + N'@AllowNonAccessibleSecondaries = 1, ');

	SET @userBackups = REPLACE(@userBackups, N'{backupType}', N'FULL');
	SET @userBackups = REPLACE(@userBackups, N'{targets}', N'{USER}');
	SET @userBackups = REPLACE(@userBackups, N'{retention}', @UserFullBackupRetention);
	SET @userBackups = REPLACE(@userBackups, N'{copyRetention}', ISNULL(@CopyToUserFullBackupRetention, N''));
	SET @userBackups = REPLACE(@userBackups, N'{exclusions}', @FullAndLogUserDBExclusions);

	-- log backups: 
	SET @logBackups = @backupsTemplate;

	IF @AllowForSecondaryServers = 0 
		SET @logBackups = REPLACE(@logBackups, N'{secondaries}', N'');
	ELSE 
		SET @logBackups = REPLACE(@logBackups, N'{secondaries}', @crlfTab + N'@AllowNonAccessibleSecondaries = 1, ');

	SET @logBackups = REPLACE(@logBackups, N'{backupType}', N'LOG');
	SET @logBackups = REPLACE(@logBackups, N'{targets}', N'{USER}');
	SET @logBackups = REPLACE(@logBackups, N'{retention}', @LogBackupRetention);
	SET @logBackups = REPLACE(@logBackups, N'{copyRetention}', ISNULL(@CopyToLogBackupRetention, N''));
	SET @logBackups = REPLACE(@logBackups, N'{exclusions}', @FullAndLogUserDBExclusions);

	DECLARE @jobs table (
		job_id int IDENTITY(1,1) NOT NULL, 
		job_name sysname NOT NULL, 
		job_step_name sysname NOT NULL, 
		job_body nvarchar(MAX) NOT NULL,
		job_start_time time NULL
	);

	INSERT INTO @jobs (
		[job_name],
		[job_step_name],
		[job_body],
		[job_start_time]
	)
	VALUES	
	(
		N'SYSTEM - Full', 
		N'FULL Backup of SYSTEM Databases', 
		@sysBackups, 
		@systemStart
	), 
	(
		N'USER - Full', 
		N'FULL Backup of USER Databases', 
		@userBackups, 
		@userStart
	), 
	(
		N'USER - Log', 
		N'TLOG Backup of USER Databases', 
		@LogBackups, 
		@logStart
	);
	
	DECLARE @currentJobSuffix sysname, @currentJobStep sysname, @currentJobStepBody nvarchar(MAX), @currentJobStart time;

	DECLARE @currentJobName sysname;
	DECLARE @existingJob sysname; 
	DECLARE @jobID uniqueidentifier;

	DECLARE @dateAsInt int;
	DECLARE @startTimeAsInt int; 
	DECLARE @scheduleName sysname;

	DECLARE @schedSubdayType int; 
	DECLARE @schedSubdayInteval int; 
	
	DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[job_name],
		[job_step_name],
		[job_body],
		[job_start_time]
	FROM 
		@jobs
	WHERE 
		[job_start_time] IS NOT NULL -- don't create jobs for 'tasks' without start times.
	ORDER BY 
		[job_id];
	
	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @currentJobSuffix, @currentJobStep, @currentJobStepBody, @currentJobStart;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
	
		SET @currentJobName =  @JobsNamePrefix + @currentJobSuffix;

		SET @jobID = NULL;
		EXEC [admindb].[dbo].[create_agent_job]
			@TargetJobName = @currentJobName,
			@JobCategoryName = @JobsCategoryName,
			@AddBlankInitialJobStep = 1,
			@OperatorToAlertOnErrorss = @JobOperatorToAlertOnErrors,
			@OverWriteExistingJobDetails = @OverWriteExistingJobs,
			@JobID = @jobID OUTPUT;
		
		-- create a schedule:
		SET @dateAsInt = CAST(CONVERT(sysname, GETDATE(), 112) AS int);
		SET @startTimeAsInt = CAST((LEFT(REPLACE(CONVERT(sysname, @currentJobStart, 108), N':', N''), 6)) AS int);
		SET @scheduleName = @currentJobName + N' Schedule';

		IF @currentJobName LIKE '%log%' BEGIN 
			SET @schedSubdayType = 1; -- every N minutes
			SET @schedSubdayInteval = @frequencyMinutes;	 -- N... 
		  END; 
		ELSE BEGIN 
			SET @schedSubdayType = 1; -- at the specified (start) time. 
			SET @schedSubdayInteval = 0
		END;

		EXEC msdb.dbo.sp_add_jobschedule 
			@job_id = @jobId,
			@name = @scheduleName,
			@enabled = 1, 
			@freq_type = 4,  -- daily										
			@freq_interval = 1,  -- every 1 days... 								
			@freq_subday_type = @schedSubdayType,							
			@freq_subday_interval = @schedSubdayInteval, 
			@freq_relative_interval = 0, 
			@freq_recurrence_factor = 0, 
			@active_start_date = @dateAsInt, 
			@active_start_time = @startTimeAsInt;

		-- now add the job step:
		EXEC msdb..sp_add_jobstep
			@job_id = @jobId,
			@step_id = 2,		-- place-holder already defined for step 1
			@step_name = @currentJobStep,
			@subsystem = N'TSQL',
			@command = @currentJobStepBody,
			@on_success_action = 1,		-- quit reporting success
			@on_fail_action = 2,		-- quit reporting failure 
			@database_name = N'admindb',
			@retry_attempts = 0,
			@retry_interval = 0;
	
	FETCH NEXT FROM [walker] INTO @currentJobSuffix, @currentJobStep, @currentJobStepBody, @currentJobStart;
	END;
	
	CLOSE [walker];
	DEALLOCATE [walker];
	
	RETURN 0;
GO