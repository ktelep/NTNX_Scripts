## Fix for Pulse issue on CE2.0 clusters upgraded to 6.5.4+

Patch process:

1.  Copy the appropriate .diff file in this repo to each CVM via SCP or WinSCP to /home/nutanix (Note, the patch file is different for 6.8)
2.  Open an ssh session to the CVM as the 'nutanix' user
3.  Confirm the Pulse SMTP is failed or disabled

```
nutanix@NTNX-94e510df-A-CVM$ ncli pulse-config ls
```

4.  Execute the following command to patch the serviceability script

```
nutanix@NTNX-94e510df-A-CVM$ patch ~/serviceability/bin/cron_serviceability.py ~/pulse_fix.diff
```
5. Run the cron_serviceability script manually to confirm no syntax errors or issues
```
nutanix@NTNX-94e510df-A-CVM$ ~/serviceability/bin/cron_serviceability.py
```
6.  Repeat this on each node in the CE cluster

7.  Wait 5-10 minutes for the pulse tunnel to come up on the Prism Leader node

```
nutanix@NTNX-94e510df-A-CVM$ ncli pulse-config ls

    Status                    : Enabled
    Enable Default Nutanix... : true
    Default Nutanix Email     : nos-asups@nutanix.com
    Email Contacts            :
    Verbosity                 : BASIC_COREDUMP
    SMTP Tunnel Status        : success
    Service Center            : nsc02.nutanix.net
    Tunnel Connected Since    : Mon May 13 15:50:12 UTC 2024
  ```
 
8. Attempt to log into Prism

