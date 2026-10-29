// Pauses the NF Journey Cleanup schedule (scripts/deploy.ps1 re-schedules it with nf_03_scheduleCleanup.apex).
for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'NF Journey Cleanup']) System.abortJob(ct.Id);
