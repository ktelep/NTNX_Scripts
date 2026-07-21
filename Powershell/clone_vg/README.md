Quick script to handle VG cloning with the V4 API.

Provide the PC IP, Username, Password, Target VM, List of source VGs, and List of Target VGs and this script will detach and delete those VGs from the target system, clone the source VGs into new VGs with the same Target VG name and attach them to the host.   This is the functional equivalent of doing a Pure storage overwrite snapshot restore.


