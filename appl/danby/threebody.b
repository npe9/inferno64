implement Threebody;
include "sys.m";
include "draw.m";
Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
Threebody: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/orbital.dis";
	if(client == nil)
		raise "fail:Threebody: cannot load orbital interface";
	client->init(ctxt,"threebody" :: "/dis/danby/plugin/threebody.dis" :: "danby-threebody" :: nil);
}
