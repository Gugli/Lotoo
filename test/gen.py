import zipfile
import os

LocalDir = os.path.dirname(os.path.realpath(__file__))

with zipfile.ZipFile(os.path.join(LocalDir, 'test.zip'), 'w') as testzip:
	for i in range(0,100):
		testzip.writestr('answer{:03d}.txt'.format(i), 'question{:03d}'.format(i))