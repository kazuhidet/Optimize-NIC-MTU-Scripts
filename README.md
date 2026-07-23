# Optimize-NIC-MTU-Scripts

Recently, I ran into repeated network disconnection issues on a PC where I had just installed Windows 11.

After investigating the cause, it seemed that the problem was related to the MTU setting on the NIC. The MTU was still set to the default value of 1500, and that appeared to be degrading network communication.

I tried accessing a website I found through Google that was supposed to help determine the optimal MTU value, but it had turned into a site overloaded with unnecessary ads and was no longer useful.

So, I ended up writing a PowerShell script that detects the optimal MTU value for a NIC on Windows 10 and Windows 11.

## Directory structure

- Windows/
Windows valuersiom PowerShell script and README.md
- Linux/
Linux versiom Shell script and README.md


