implement Productionexchange;
include "sys.m";
include "draw.m";
Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
Productionexchange: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
init(ctxt: ref Draw->Context, nil: list of string)
{
	client := load Command "/dis/temple/populations.dis";
	if(client == nil)
		raise "fail:Productionexchange: cannot load model interface";
	client->init(ctxt,
		"productionexchange" :: "/dis/danby/productionexchange.dis" ::
		"danby-productionexchange" :: nil);
}
