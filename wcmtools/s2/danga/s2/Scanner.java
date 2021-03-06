package danga.s2;

import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.BufferedReader;

public class Scanner
{
    public int line;
    public int col;

    BufferedReader is;
    
    boolean havePeeked;
    char peekedChar;
    boolean fakeNewline = false;

    boolean bogusInput = false;

    public Scanner (InputStream is)
    {
        try {
            this.is = new BufferedReader(new InputStreamReader(is, "UTF-8"), 4096);
        } catch (Exception e) {
            System.err.println("Scanner Error: "+e);
        }
	line = 1;
	col = 1;
	havePeeked = false;
    }

    public boolean getBogusFlag() {
        return bogusInput;
    }

    public char peek ()
    {
	if (havePeeked) {
	    return peekedChar;
	}

	havePeeked = true;
	try {
	    peekedChar = (char) is.read();
            if (peekedChar == (char) 0) peekedChar = (char) -1;
	} catch (Exception e) {
            bogusInput = true;
	    peekedChar = (char) -1;
	}

	return peekedChar;
    }

    // get a char, or -1 if the end of the stream is hit.    
    public char getChar ()
    {
	char ch = peek();
	havePeeked = false;

	if (ch == '\n') {
	    if (fakeNewline) {
		fakeNewline = false;
	    } else {
		line++;
		col = 0;
	    }
	}
	if (ch == '\t')
	    col += 4;   // stupid assumption.
	else
	    col++;

	return ch;
    }

    public void forceNextChar (char ch)
    {
	if (ch == '\n') fakeNewline = true;
	havePeeked = true;
	peekedChar = ch;
    }

    public String locationString () 
    {
	return ("line " + line + ", column " + col + ".");
    }

    // get a char that isn't an end of file.
    public char getRealChar () throws Exception
    {
	char ch = getChar();
	if (ch == -1) {
	    throw new Exception("Unexpected end of file!");
	}
	return ch;
    }


}
