function TtlCache(a, b) {
	let self = proto({}, {
		get: function(key) { return this.entries[key]; },
		set: function(key, value) { this.entries[key] = value; },
	});
	self.ttl_ms = a;
	self.maxsize = b;
	self.entries = {};
	return self;
}
let c = TtlCache(300, 10);
c.set("x", 42);
print(c.get("x"), " ", c.ttl_ms);
