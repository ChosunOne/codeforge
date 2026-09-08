function! codeforge#receive(path) abort
        return luaeval("require('codeforge.transport').receive_file_strict(_A)", a:path)
endfunction
