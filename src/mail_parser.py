import imaplib
import email

def extraer_correos(usuario, password):
    mail = imaplib.IMAP4_SSL('imap.gmail.com')
    mail.login(usuario, password)
    mail.select('Banca_Agente')
    
    _, data = mail.search(None, 'UNSEEN')
    correos = []
    
    for num in data[0].split():
        _, msg_data = mail.fetch(num, '(RFC822)')
        msg = email.message_from_bytes(msg_data[0][1])
        cuerpo = msg.get_payload(decode=True).decode() if not msg.is_multipart() else msg.walk()[0].get_payload(decode=True).decode()
        
        # Blindaje: Truncar a 1000 caracteres
        correos.append(cuerpo[:1000])
        
    return correos