Screenlocker
============

USB-Key based screen locking for linux. Kind of inspired by rohos for windows, but does not require a specific device - any USB device with a unique serial number will work.

Unlocking should work on any freedesktop compatible screenlocker that supports a dbus call to `org.freedesktop.ScreenSaver.SetActive`, with a special exception for KDE 4.10 onwards which decided to just break compatability... (See: https://bugs.kde.org/show_bug.cgi?id=314989)

If it doesn't work, feel free to raise an issue about it and/or a pull request to fix it.

Usage
============
Insert your usb device of choice and run `./screenlocker.sh -s` to set it up.

Once set up, insert and remove your key!

Advanced Usage
============
If you pass a `-u` parameter to the setup then ALL usb devices will be checked rather than just devices that are "known good"

You can also pass `-k <keyfile>` to allow setting up multiple unlock keys

Bugs and Known issues
============

See: https://github.com/ShaneMcC/screenlocker/issues

This is a pretty simple script, so there shouldn't really be much in the way of bugs.
