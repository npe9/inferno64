#!/usr/bin/env python3
"""Prove Bounce AABB wall math (mirrors appl/wm/bounce.b wallbounce)."""

def absr(x):
    return -x if x < 0 else x

def wallbounce(px, py, vx, vy, w, h, bs):
    hit = 0
    if px < bs:
        px = bs
        vx = absr(vx)
        hit = 1
    elif px > w - bs:
        px = w - bs
        vx = -absr(vx)
        hit = 1
    if py < bs:
        py = bs
        vy = absr(vy)
        hit = 1
    elif py > h - bs:
        py = h - bs
        vy = -absr(vy)
        hit = 1
    return px, py, vx, vy, hit

def old_int_wall_hit(hp_y, wall_y=-1):
    # Original bounce.b used int(hp.y) vs wall at y=-1; truncation misses.
    return int(hp_y) >= wall_y and int(hp_y) <= wall_y

def main():
    # Top wall approach (already past bs)
    px, py, vx, vy, hit = wallbounce(10.0, 3.0, 0.0, -1.0, 100.0, 100.0, 4.0)
    assert hit == 1 and py == 4.0 and vy > 0.0, (px, py, vx, vy, hit)

    # Right wall
    px, py, vx, vy, hit = wallbounce(99.0, 50.0, 1.0, 0.0, 100.0, 100.0, 4.0)
    assert hit == 1 and px == 96.0 and vx < 0.0

    # Old int truncation fails for near-wall hit
    assert not old_int_wall_hit(-0.5), "expected int trunc miss"
    assert old_int_wall_hit(-1.0)

    # Simulate steps: never leave box
    px, py, vx, vy = 50.0, 50.0, 0.8, -0.6
    speed, bs, w, h = 1.5, 4.0, 400.0, 400.0
    for _ in range(5000):
        px += vx * speed
        py += vy * speed
        px, py, vx, vy, _ = wallbounce(px, py, vx, vy, w, h, bs)
        assert bs <= px <= w - bs and bs <= py <= h - bs

    print("bounce-aabb-proof: OK")

if __name__ == "__main__":
    main()
