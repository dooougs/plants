-- FIFO with O(1) pops. Sort/reprioritize only the remaining jobs.
local Queue = {}
function Queue.new(values)
	return { items = values or {}, first = 1, last = if values then #values else 0 }
end
function Queue.count(q) return q.last - q.first + 1 end
function Queue.peek(q) return q.items[q.first] end
function Queue.push(q, value)
	if q.first > 1024 and q.first > q.last / 2 then
		q.items = Queue.values(q)
		q.first, q.last = 1, #q.items
	end
	q.last += 1
	q.items[q.last] = value
end
function Queue.pop(q)
	if q.first > q.last then return nil end
	local value = q.items[q.first]
	q.items[q.first] = nil
	q.first += 1
	if q.first > q.last then q.first, q.last = 1, 0 end
	return value
end
function Queue.clear(q)
	table.clear(q.items)
	q.first, q.last = 1, 0
end
function Queue.values(q)
	local values = {}
	for i = q.first, q.last do table.insert(values, q.items[i]) end
	return values
end
function Queue.sort(q, compare)
	q.items = Queue.values(q)
	q.first, q.last = 1, #q.items
	table.sort(q.items, compare)
end
return Queue
