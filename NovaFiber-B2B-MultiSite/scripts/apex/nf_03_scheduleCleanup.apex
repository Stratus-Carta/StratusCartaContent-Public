// Schedules the hourly cleanup of abandoned NovaFiber journeys (re-runnable).
for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'NF Journey Cleanup']) System.abortJob(ct.Id);
System.debug('NF scheduled ' + System.schedule('NF Journey Cleanup', '0 15 * * * ?', new NF_JourneyCleanup()));
