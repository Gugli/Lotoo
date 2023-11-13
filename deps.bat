@ECHO off

SET LocalDir=%~dp0
SET libzipVer=3.0.2
SET libzipFile=%LocalDir%\deps\miniz-%libzipVer%.tar.gz

IF NOT EXIST %LocalDir%\deps (
	MKDIR %LocalDir%\deps
)

IF NOT EXIST %libzipFile% (
	curl --location --output %libzipFile% https://github.com/richgel999/miniz/releases/download/%libzipVer%/miniz-%libzipVer%.zip
)

IF NOT EXIST %LocalDir%\deps\miniz (
	CD %LocalDir%\deps
	tar -xf %libzipFile% miniz.c miniz.h
)
