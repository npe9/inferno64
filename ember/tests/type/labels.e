module Labels

import sys "sys"

func init() {
	total := 0
outer:
	for i := 0; i < 5; i++ {
		for j := 0; j < 5; j++ {
			if j == 3 {
				continue outer
			}
			if i == 4 {
				break outer
			}
			total = total + 1
		}
	}
	sys.print("total=%d\n", total)
}
