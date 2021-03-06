#!/usr/bin/env python
#
# Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

# Updates the list of Observatory source files.

import os
import sys
from datetime import date

def getDir(rootdir, target):
  sources = []
  for root, subdirs, files in os.walk(rootdir):
    subdirs.sort()
    files.sort()
    for f in files:
      sources.append(root + '/' + f)
  return sources

HEADER = """# Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

# DO NOT EDIT. This file is generated by update_sources.py in this directory.

# This file contains all dart, css, and html sources for Observatory.
"""

def main():
  with open('observatory_sources.gni', 'w') as target:
    target.write(HEADER)
    target.write('observatory_sources = [\n')
    sources = []
    for rootdir in ['lib', 'web']:
      sources.extend(getDir(rootdir, target))
    sources.sort()
    for s in sources:
      if (s[-9:] != 'README.md'):
        target.write('  "' + s + '",\n')
    target.write(']\n')

if __name__ == "__main__":
   main()
