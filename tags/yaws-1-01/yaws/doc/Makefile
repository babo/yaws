



all debug:	yaws.ps yaws.pdf

yaws.ps:	yaws.dvi
	-dvips -o yaws.ps yaws.dvi
	-cp yaws.ps ../www

yaws.pdf:	yaws.dvi
	-dvipdf yaws.dvi
	cp yaws.pdf ../www

yaws.dvi:	yaws.tex
	-latex yaws.tex

clean:
	-rm *~ *.ps *.dvi *.log *.aux *.pdf *.toc *.beam 2> /dev/null

install:
	-install -d /usr/local/share/doc/yaws
	-cp yaws.pdf yaws.ps /usr/local/share/doc/yaws
