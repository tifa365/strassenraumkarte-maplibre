#!/usr/bin/env python3
"""Rebuild highway (layered) from highway (unlayered) template with layer filters."""

from __future__ import annotations

import copy
import re
import shutil
import sys
import uuid
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

LAYER_FILTERS: list[tuple[str, str]] = [
    ("layer >= 3", '"layer" >= 3'),
    ("layer = 2", '"layer" = 2'),
    ("layer = 1", '"layer" = 1'),
    ("layer = 0", '"layer" = 0 OR "layer" IS NULL'),
    ("layer = -1", '"layer" = -1'),
    ("layer <= -2", '"layer" <= -2'),
]


def combine_sql(existing_sql: str | None, layer_filter: str) -> str:
    if existing_sql:
        return f"({existing_sql}) AND ({layer_filter})"
    return layer_filter


def extract_sql_from_datasource(datasource: str) -> tuple[str, str | None]:
    marker = " sql="
    idx = datasource.find(marker)
    if idx == -1:
        return datasource, None
    return datasource[:idx], datasource[idx + len(marker) :]


def decode_source_attr(value: str) -> str:
    return (
        value.replace("&quot;", '"')
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
    )


def encode_source_attr(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def extract_sql_from_source_attr(source: str) -> tuple[str, str | None]:
    marker = " sql="
    idx = source.find(marker)
    if idx == -1:
        return source, None
    return source[:idx], decode_source_attr(source[idx + len(marker) :])


def add_layer_filter_to_datasource(datasource: str, layer_filter: str) -> str:
    base, existing = extract_sql_from_datasource(datasource)
    return f"{base} sql={combine_sql(existing, layer_filter)}"


def add_layer_filter_to_source_attr(source: str, layer_filter: str) -> str:
    base, existing = extract_sql_from_source_attr(source)
    combined = encode_source_attr(combine_sql(existing, layer_filter))
    return f"{base} sql={combined}"


def new_layer_id(base_name: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9_]+", "_", base_name).strip("_").lower()
    return f"{slug}_{uuid.uuid4().hex}"


def collect_layer_ids(group: ET.Element) -> set[str]:
    ids: set[str] = set()
    for child in group:
        if child.tag == "layer-tree-layer":
            ids.add(child.get("id", ""))
        elif child.tag == "layer-tree-group":
            ids.update(collect_layer_ids(child))
    return ids


def apply_layer_filter_to_tree(group: ET.Element, layer_filter: str, id_map: dict[str, str]) -> None:
    for child in group:
        if child.tag == "layer-tree-layer":
            old_id = child.get("id", "")
            new_id = new_layer_id(child.get("name", "layer"))
            id_map[old_id] = new_id
            child.set("id", new_id)
            source = child.get("source")
            if source:
                child.set("source", add_layer_filter_to_source_attr(source, layer_filter))
        elif child.tag == "layer-tree-group":
            apply_layer_filter_to_tree(child, layer_filter, id_map)


def build_legend_from_tree(tree_group: ET.Element) -> ET.Element:
    def walk_tree(node: ET.Element, legend_parent: ET.Element) -> None:
        for child in node:
            if child.tag == "layer-tree-group":
                subgroup = ET.SubElement(legend_parent, "legendgroup")
                subgroup.set("open", child.get("expanded", "0"))
                subgroup.set("name", child.get("name", ""))
                subgroup.set("checked", child.get("checked", "Qt::Checked"))
                walk_tree(child, subgroup)
            elif child.tag == "layer-tree-layer":
                expanded = child.get("expanded", "0")
                legendlayer = ET.SubElement(legend_parent, "legendlayer")
                legendlayer.set("open", expanded)
                legendlayer.set("showFeatureCount", "0")
                legendlayer.set("name", child.get("name", ""))
                legendlayer.set("drawingOrder", "-1")
                legendlayer.set("checked", child.get("checked", "Qt::Checked"))
                filegroup = ET.SubElement(legendlayer, "filegroup")
                filegroup.set("open", expanded)
                filegroup.set("hidden", "false")
                legendlayerfile = ET.SubElement(filegroup, "legendlayerfile")
                legendlayerfile.set("layerid", child.get("id", ""))
                legendlayerfile.set("isInOverview", "0")
                legendlayerfile.set("visible", "0")

    result = ET.Element("legendgroup")
    walk_tree(tree_group, result)
    return result


def clone_maplayer(template: ET.Element, new_id: str, layer_filter: str) -> ET.Element:
    cloned = copy.deepcopy(template)
    id_elem = cloned.find("id")
    if id_elem is not None:
        id_elem.text = new_id
    ds_elem = cloned.find("datasource")
    if ds_elem is not None and ds_elem.text:
        ds_elem.text = add_layer_filter_to_datasource(ds_elem.text, layer_filter)
    return cloned


def find_parent(root: ET.Element, target: ET.Element) -> ET.Element | None:
    for parent in root.iter():
        for child in parent:
            if child is target:
                return parent
    return None


def replace_element(parent: ET.Element, old: ET.Element, new: ET.Element) -> None:
    for idx, child in enumerate(parent):
        if child is old:
            parent.remove(old)
            parent.insert(idx, new)
            return


def update_id_references(root: ET.Element, remove_ids: set[str], add_ids: list[str]) -> None:
    layerorder = root.find("layerorder")
    if layerorder is not None:
        items = layerorder.findall("layer")
        new_layers: list[ET.Element] = []
        first_idx: int | None = None
        for item in items:
            lid = item.get("id", "")
            if lid in remove_ids:
                if first_idx is None:
                    first_idx = len(new_layers)
                continue
            new_layers.append(item)
        insert_at = first_idx if first_idx is not None else len(new_layers)
        for offset, lid in enumerate(add_ids):
            elem = ET.Element("layer")
            elem.set("id", lid)
            new_layers.insert(insert_at + offset, elem)
        layerorder.clear()
        layerorder.extend(new_layers)

    for custom_order in root.iter("custom-order"):
        items = custom_order.findall("item")
        new_items: list[ET.Element] = []
        first_idx: int | None = None
        for item in items:
            if item.text in remove_ids:
                if first_idx is None:
                    first_idx = len(new_items)
                continue
            new_items.append(item)
        insert_at = first_idx if first_idx is not None else len(new_items)
        for offset, lid in enumerate(add_ids):
            elem = ET.Element("item")
            elem.text = lid
            new_items.insert(insert_at + offset, elem)
        custom_order.clear()
        custom_order.extend(new_items)

    snapping = root.find("snapping-settings")
    if snapping is not None:
        individual = snapping.find("individual-layer-settings")
        if individual is not None:
            for setting in list(individual.findall("layer-setting")):
                if setting.get("id") in remove_ids:
                    individual.remove(setting)


def add_snapping_settings(root: ET.Element, new_ids: list[str]) -> None:
    snapping = root.find("snapping-settings")
    if snapping is None:
        return
    individual = snapping.find("individual-layer-settings")
    if individual is None:
        return
    for lid in new_ids:
        setting = ET.Element("layer-setting")
        setting.set("id", lid)
        setting.set("type", "1")
        setting.set("units", "1")
        setting.set("minScale", "0")
        setting.set("enabled", "0")
        setting.set("tolerance", "12")
        setting.set("maxScale", "0")
        individual.append(setting)


def process_qgs(qgs_path: Path) -> None:
    tree = ET.parse(qgs_path)
    root = tree.getroot()

    unlayered_tree = layered_tree = layered_legend = None
    for elem in root.iter("layer-tree-group"):
        if elem.get("name") == "highway (unlayered)":
            unlayered_tree = elem
        elif elem.get("name") == "highway (layered)":
            layered_tree = elem

    for elem in root.iter("legendgroup"):
        if elem.get("name") == "highway (layered)":
            layered_legend = elem

    if unlayered_tree is None or layered_tree is None:
        raise RuntimeError("Could not find highway (unlayered) or highway (layered) groups")

    old_layered_ids = collect_layer_ids(layered_tree)

    maplayers_parent = root.find("projectlayers")
    if maplayers_parent is None:
        raise RuntimeError("Could not find projectlayers")

    maplayers_by_id: dict[str, ET.Element] = {}
    for ml in maplayers_parent.findall("maplayer"):
        id_elem = ml.find("id")
        if id_elem is not None and id_elem.text:
            maplayers_by_id[id_elem.text] = ml

    unlayered_children = [
        copy.deepcopy(child)
        for child in unlayered_tree
        if child.tag == "layer-tree-group"
    ]

    new_layered_tree = ET.Element("layer-tree-group")
    new_layered_tree.set("expanded", layered_tree.get("expanded", "0"))
    new_layered_tree.set("name", "highway (layered)")
    new_layered_tree.set("checked", layered_tree.get("checked", "Qt::Unchecked"))
    new_layered_tree.set("groupLayer", "")
    cp = ET.SubElement(new_layered_tree, "customproperties")
    ET.SubElement(cp, "Option")

    new_layered_legend = ET.Element("legendgroup")
    new_layered_legend.set("open", layered_legend.get("open", "false") if layered_legend is not None else "false")
    new_layered_legend.set("name", "highway (layered)")
    new_layered_legend.set("checked", layered_legend.get("checked", "Qt::Unchecked") if layered_legend is not None else "Qt::Unchecked")

    all_new_ids: list[str] = []
    new_maplayers: list[ET.Element] = []

    for group_name, layer_filter in LAYER_FILTERS:
        filter_group = ET.Element("layer-tree-group")
        filter_group.set("expanded", "0")
        filter_group.set("name", group_name)
        filter_group.set("checked", "Qt::Checked")
        filter_group.set("groupLayer", "")
        cp = ET.SubElement(filter_group, "customproperties")
        ET.SubElement(cp, "Option")

        id_map: dict[str, str] = {}
        for template_child in unlayered_children:
            cloned = copy.deepcopy(template_child)
            apply_layer_filter_to_tree(cloned, layer_filter, id_map)
            filter_group.append(cloned)

        filter_legend = build_legend_from_tree(filter_group)
        filter_legend.set("open", "false")
        filter_legend.set("name", group_name)
        filter_legend.set("checked", "Qt::Checked")
        new_layered_legend.append(filter_legend)
        new_layered_tree.append(filter_group)

        for source_id, new_id in id_map.items():
            template_ml = maplayers_by_id.get(source_id)
            if template_ml is None:
                print(f"Warning: no maplayer for {source_id}", file=sys.stderr)
                continue
            new_maplayers.append(clone_maplayer(template_ml, new_id, layer_filter))
            all_new_ids.append(new_id)

    for ml in list(maplayers_parent.findall("maplayer")):
        id_elem = ml.find("id")
        if id_elem is not None and id_elem.text in old_layered_ids:
            maplayers_parent.remove(ml)
    maplayers_parent.extend(new_maplayers)

    tree_parent = find_parent(root, layered_tree)
    if tree_parent is None:
        raise RuntimeError("Could not find parent of highway (layered) tree group")
    replace_element(tree_parent, layered_tree, new_layered_tree)

    if layered_legend is not None:
        legend_parent = find_parent(root, layered_legend)
        if legend_parent is not None:
            replace_element(legend_parent, layered_legend, new_layered_legend)

    update_id_references(root, old_layered_ids, all_new_ids)
    add_snapping_settings(root, all_new_ids)

    tree.write(qgs_path, encoding="UTF-8", xml_declaration=True)

    print(f"Removed {len(old_layered_ids)} old layered layers")
    print(f"Added {len(all_new_ids)} new layered layers")
    print(f"  ({len(unlayered_children)} template groups × {len(LAYER_FILTERS)} layer filters)")


def process_qgz(qgz_path: Path) -> None:
    work_dir = qgz_path.parent / f".{qgz_path.stem}_layered_work"
    if work_dir.exists():
        shutil.rmtree(work_dir)
    work_dir.mkdir()

    others: list[tuple[str, bytes]] = []
    qgs_path: Path | None = None

    with zipfile.ZipFile(qgz_path, "r") as zf:
        for name in zf.namelist():
            data = zf.read(name)
            if name.endswith(".qgs"):
                qgs_path = work_dir / name
                qgs_path.write_bytes(data)
            else:
                others.append((name, data))

    if qgs_path is None:
        raise FileNotFoundError(f"No .qgs in {qgz_path}")

    bak = qgz_path.with_suffix(qgz_path.suffix + ".bak")
    shutil.copy2(qgz_path, bak)
    print(f"Backup: {bak}")

    process_qgs(qgs_path)

    tmp = qgz_path.with_suffix(qgz_path.suffix + ".tmp")
    with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.write(qgs_path, qgs_path.name)
        for name, data in others:
            zf.writestr(name, data)
    tmp.replace(qgz_path)
    print(f"Updated {qgz_path}")


def main() -> None:
    qgz = Path(__file__).resolve().parent / "strassenraumkarte.qgz"
    if len(sys.argv) > 1:
        qgz = Path(sys.argv[1])
    process_qgz(qgz)


if __name__ == "__main__":
    main()
