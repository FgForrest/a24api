a24api
======

Access to Active24 SOAP API


Usage
-----

    Usage: ./a24api.pl [options] <service> <function> [parameters]

    Options:
        -c <variant> Use alternative cfg. file a24api-cfg-<variant>.json
                     If omitted, cfg. file a24api-cfg-default.json is used.
    Services:
        dns - DNS record management
            dns list <domain> [-t <type>] [-fn <name regex filter>] [-fv <value regex filter>]
            dns delete <domain> <record id>

            A, AAAA, CNAME, TXT
                dns create <domain> <name> <ttl> <type> <value>
                dns update <domain> <record id> <name> <ttl> <type> <value>
            MX
                dns create <domain> <name> <ttl> <type> <priority> <value>
                dns update <domain> <record id> <name> <ttl> <type> <priority> <value>
