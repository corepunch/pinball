"""A table's XML and the dictionary the game's JSON is written from, in both directions.

Attributes hold values, and lists are written out: `a="0.1 0.2"`, `points="0.1,0.2 0.3,0.4"`,
with `arc(cx,cy,r,from,to,steps)` in a point list. Lists of things are a container of elements.
"""
import xml.etree.ElementTree as ET

WORDS = {'layers', 'members', 'lamps', 'actions'}             # Lists of names.
NUMBERS = {'a', 'b', 'pivot', 'passDirection', 'ejectDirection'}  # Lists of numbers.
POINTS = {'points', 'mouth', 'columns'}                        # Lists of points.
CONTAINERS = {'walls': 'wall', 'flippers': 'flipper', 'bumpers': 'bumper', 'slingshots': 'slingshot',
              'dropTargets': 'dropTarget', 'standups': 'standup', 'rollovers': 'rollover', 'spinners': 'spinner',
              'saucers': 'saucer', 'gates': 'gate', 'kickbacks': 'kickback', 'magnets': 'magnet',
              'captiveBalls': 'captiveBall', 'flashers': 'flasher', 'ramps': 'ramp', 'lamps': 'lamp',
              'plastics': 'plastic', 'decor': 'item', 'posts': 'post', 'groups': 'group'}


def number(text):
    return int(text) if text.lstrip('-').isdigit() else float(text)


def scalar_text(value):
    if isinstance(value, bool):
        return 'true' if value else 'false'
    return repr(value) if isinstance(value, float) else str(value)


def points_text(points):
    out = []
    for p in points:
        if isinstance(p, dict):
            out.append('arc(' + ','.join(scalar_text(c) for c in p['arc']) + ')')
        else:
            out.append(','.join(scalar_text(c) for c in p))
    return ' '.join(out)


def points_value(text):
    out = []
    for word in text.split():
        if word.startswith('arc('):
            out.append({'arc': [number(c) for c in word[4:-1].split(',')]})
        else:
            out.append([number(c) for c in word.split(',')])
    return out


def to_element(tag, item):
    element = ET.Element(tag)
    for key, value in item.items():
        if isinstance(value, list) and value and isinstance(value[0], dict) and 'arc' not in value[0]:
            container = ET.SubElement(element, key)
            for child in value:
                container.append(to_element(CONTAINERS[key], child))
        elif key in POINTS:
            element.set(key, points_text(value))
        elif key in WORDS or key in NUMBERS or (tag == 'table' and key == 'size'):
            element.set(key, ' '.join(scalar_text(v) for v in value))
        elif isinstance(value, dict):
            element.append(to_element(key, value))
        elif isinstance(value, list):
            container = ET.SubElement(element, key)
            for child in value:
                container.append(to_element(CONTAINERS[key], child))
        else:
            element.set(key, scalar_text(value))
    return element


def attribute_value(tag, key, text):
    if key in POINTS:
        return points_value(text)
    if key in WORDS:
        return text.split()
    if key in NUMBERS or (tag == 'table' and key == 'size'):
        return [number(c) for c in text.split()]
    if text in ('true', 'false'):
        return text == 'true'
    try:
        return number(text)
    except ValueError:
        return text


def from_element(element):
    item = {key: attribute_value(element.tag, key, text) for key, text in element.attrib.items()}
    for child in element:
        if child.tag in CONTAINERS:
            item[child.tag] = [from_element(entry) for entry in child]
        else:
            item[child.tag] = from_element(child)
    return item


def write(table, path):
    root = to_element('table', table)
    ET.indent(root, space=' ')
    ET.ElementTree(root).write(path, encoding='unicode')
    with open(path, 'a') as handle:
        handle.write('\n')


def read(path):
    return from_element(ET.parse(path).getroot())
