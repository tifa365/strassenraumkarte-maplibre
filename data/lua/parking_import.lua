-- Isolated flex import used by data/build_parking.sh.
--
-- This file deliberately keeps the source OSM objects intact.  The normal
-- map import derives and offsets lanes while importing; that is unsuitable as
-- input to the Supaplex parking calculation.  Every object is therefore
-- copied to a generation schema with its original tags and way node order.

local roads = osm2pgsql.define_table({
    name = 'raw_ways',
    ids = { type = 'any', type_column = 'osm_type', id_column = 'osm_id' },
    columns = {
        { column = 'tags', type = 'jsonb' },
        { column = 'node_ids', type = 'jsonb' },
        { column = 'is_area', type = 'boolean' },
        { column = 'geom', type = 'linestring', projection = 3857, not_null = true },
    }
})

local nodes = osm2pgsql.define_table({
    name = 'raw_nodes',
    ids = { type = 'any', type_column = 'osm_type', id_column = 'osm_id' },
    columns = {
        { column = 'tags', type = 'jsonb' },
        { column = 'geom', type = 'point', projection = 3857, not_null = true },
    }
})

local relations = osm2pgsql.define_table({
    name = 'raw_relations',
    ids = { type = 'any', type_column = 'osm_type', id_column = 'osm_id' },
    columns = {
        { column = 'tags', type = 'jsonb' },
        { column = 'members', type = 'jsonb' },
    }
})

local function tagged(object)
    return object.tags and next(object.tags) ~= nil
end

local function relevant_way(object)
    local t = object.tags or {}
    return t.highway ~= nil or t.amenity == 'parking' or
        t.amenity == 'parking_space' or t.area == 'parking' or
        t["area:highway"] == 'parking_space' or t.obstacle_parking == 'yes' or
        t["obstacle:parking"] == 'yes' or t.leisure == 'parklet' or tagged(object)
end

function osm2pgsql.process_way(object)
    if not relevant_way(object) then return end
    local node_ids = {}
    for i, node in ipairs(object.nodes or {}) do node_ids[i] = node end
    roads:insert({
        osm_id = object.id, tags = object.tags,
        node_ids = node_ids, is_area = object.is_closed,
        geom = object:as_linestring()
    })
end

function osm2pgsql.process_node(object)
    if tagged(object) then
        nodes:insert({osm_id = object.id, tags = object.tags,
                      geom = object:as_point()})
    end
end

function osm2pgsql.process_relation(object)
    if tagged(object) or (object.members and #object.members > 0) then
        relations:insert({osm_id = object.id,
                          tags = object.tags, members = object.members})
    end
end
