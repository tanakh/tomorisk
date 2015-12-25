{-# LANGUAGE OverloadedStrings, QuasiQuotes, RecursiveDo #-}

module Lib
    ( askMain
    ) where

import Control.Concurrent
import Control.Concurrent.MVar
import Control.Monad
import Control.Monad.Trans
import Control.Monad.Reader

import Text.Regex.TDFA
import Text.Parsec
import Text.Parsec.String

import Data.Char
import Data.JSString (pack)
import Data.Maybe
import qualified Data.ByteString as S
import qualified Data.Set as Set

import Text.Shakespeare.Text

import GHCJS.DOM
import GHCJS.DOM.Document
import GHCJS.DOM.Element as Element
import GHCJS.DOM.Node
import GHCJS.DOM.Window
import GHCJS.DOM.XMLHttpRequest as Http
import GHCJS.DOM.EventM
import GHCJS.DOM.HTMLInputElement as Input
import GHCJS.DOM.CSSStyleDeclaration
import GHCJS.DOM.HTMLTextAreaElement as TextArea
import GHCJS.DOM.KeyboardEvent
import GHCJS.DOM.HTMLElement as HTMLElement

import GHCJS.Foreign
import GHCJS.Foreign.Callback
import GHCJS.Types
import JavaScript.Object
import JavaScript.JSON as JSON
import JavaScript.Web.XMLHttpRequest as XHR

import Prelude as P

foreign import javascript unsafe "console.log($1)" consoleLog :: JSVal -> IO ()

httpGet :: String -> IO String
httpGet url = do
    res <- xhrString Request
        { reqMethod = GET
        , reqURI = pack url
        , reqLogin = Nothing
        , reqHeaders = []
        , reqWithCredentials = False
        , reqData = NoData
        }
    case contents res of
        Nothing -> P.error $ "http get failed: " ++ url
        Just ss -> return ss

httpGetBS :: String -> IO S.ByteString
httpGetBS url = do
    res <- xhrByteString Request
        { reqMethod = GET
        , reqURI = pack url
        , reqLogin = Nothing
        , reqHeaders = []
        , reqWithCredentials = False
        , reqData = NoData
        }
    case contents res of
        Nothing -> P.error $ "http get failed: " ++ url
        Just ss -> return ss

httpPost :: String -> [(JSString, String)] -> IO String
httpPost url form = do
    res <- xhrString Request
        { reqMethod = POST
        , reqURI = pack url
        , reqLogin = Nothing
        , reqHeaders = []
        , reqWithCredentials = False
        , reqData = FormData $ P.map (\(k, v) -> (k, StringVal $ pack v)) form
        }
    case contents res of
        Nothing -> P.error $ "http get failed: " ++ url
        Just ss -> return ss

getAuthToken :: String -> IO String
getAuthToken url = do
    s <- httpGet url

    case s =~ ("name=\"authenticity_token\" value=\"([a-zA-Z0-9\\+/=]+)\"" :: String) of
        [[_, token]] -> do
            return token
        _ ->
            P.error $ "fail to get auth token: " ++ s

parseResponse :: String -> Either String ()
parseResponse s =
    case s =~ ("{\"error\".*:.*\"(.*)\"}" :: String) of
        [[_, err]] -> Left err
        _ -> Right ()

login :: String -> String -> IO (Either String ())
login user pass = do
    token <- getAuthToken "https://ask.fm/login"
    -- P.print token

    s <- httpPost "https://ask.fm/login"
              [ ("login", user)
              , ("password", pass)
              , ("authenticity_token", token)
              ]
    return $ parseResponse s

-- {"error":"ユーザー名またはパスワードが不正です"}

data Ask = Ask
    { askQuestion :: String
    , askData :: String
    , askURL :: String
    }
    deriving Show

getAsks :: IO [Ask]
getAsks = go "/account/inbox"
  where
    go url = do
        -- P.print url
        s <- httpGet $ "https://ask.fm" ++ url

        asks <- case parse (many parseAsk) "" s of
            Left err -> P.error $ show err
            Right asks -> return asks

        case s =~ ("data-url=\"/account/inbox/more\\?page=([0-9]+)&amp;score=([0-9]+)\"" :: String) of
            [[_, page, score]] -> do
                more <- go $ "/account/inbox/more?page=" ++ page ++ "&score=" ++ score
                return $ asks ++ more
            _ ->
                return asks

putAns :: Ask -> String -> IO (Either String ())
putAns ask ans = do
    let url = "https://ask.fm" ++ askURL ask
    token <- getAuthToken url
    s <- httpPost url
        [ ("utf8", "✓")
        , ("authenticity_token", token)
        , ("question[answer_text]", ans)
        , ("question[answer_type]", "")
        , ("question[photo_url]", "")
        , ("question[sharing][]", "twitter")
        ]
    -- P.print s
    return $ parseResponse s

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

parseAsk :: Parser Ask
parseAsk = do
    _ <- try $ manyTill anyChar $ try $ string "<h1 class=\"streamItemContent streamItemContent-question\">"
    q <- manyTill anyChar $ try $ string "</h1>"
    _ <- manyTill anyChar $ try $ string "<span class=\"streamItemsAge\">"
    d <- manyTill anyChar $ try $ string "</span>"
    _ <- manyTill anyChar $ try $ string "<a "
    _ <- manyTill anyChar $ try $ string "href=\""
    u <- manyTill anyChar $ char '"'
    return $ Ask (trim q) (trim d) (trim u)

waitForLogin :: Document -> IO ()
waitForLogin doc = do
    mvLogin <- newEmptyMVar

    Just userText <- getElementById doc ("user" :: String)
    Just passText <- getElementById doc ("pass" :: String)

    Just loginDialog <- getElementById doc ("login-dialog" :: String)
    Just loginBtn <- getElementById doc ("login-btn" :: String)
    on loginBtn Element.click $ liftIO $ do
        Just user <- Input.getValue $ castToHTMLInputElement userText
        Just pass <- Input.getValue $ castToHTMLInputElement passText
        res <- login user pass
        case res of
            Left err -> putStrLn err
            Right _ -> do
                -- putStrLn $ "Login success"
                Just style <- getStyle loginDialog
                setProperty style ("visibility" :: String) (Just ("hidden" :: String)) ("" :: String)
                putMVar mvLogin ()

    takeMVar mvLogin

appendAsk :: Document -> Ask -> IO ()
appendAsk doc ask = do
    Just asksContainer <- getElementById doc ("asks" :: String)
    Just item <- createElement doc $ Just ("div" :: String)

    setInnerHTML item $ Just [st|
      <table width="100%">
        <tr>
          <td rowspan="2" width="64px" style="vertical-align:top;">
            <img src="tomori.jpg" width="100%">
          </td>
          <td width="65%" class="ms-font-m">
            友利奈緒
          </td>
        </tr>
        <tr>
          <td class="ms-bgColor-themeLight ms-font-l" style="padding:10px;">
            #{askQuestion ask}
          </td>
          <td style="vertical-align:bottom;">
            #{askData ask}
          </td>
        </tr>
      </table>
|]
    appendChild asksContainer $ Just item
    height <- getScrollHeight asksContainer
    setScrollTop asksContainer height
    return ()

appendAns :: Document -> String -> IO ()
appendAns doc ans = do
    Just asksContainer <- getElementById doc ("asks" :: String)
    Just item <- createElement doc $ Just ("div" :: String)

    setInnerHTML item $ Just [st|
      <table width="100%" style="margin:5px;">
        <tr>
          <td></td>
          <td width="65%">
            <div align="right" class="ms-font-m">tanakh184</div>
          </td>
          <td rowspan="2" width="64px" style="vertical-align:top;">
            <img src="me.png" width="100%">
          </td>
        </tr>
        <tr>
          <td style="vertical-align:bottom">
            <div align="right"></div>
          </td>
          <td class="ms-bgColor-neutralLight ms-font-l" style="padding:10px;">
            #{ans}
          </td>
        </tr>
      </table>
|]
    appendChild asksContainer $ Just item

    height <- getScrollHeight asksContainer
    setScrollTop asksContainer height

    return ()

waitForAnswer :: Document -> IO (Maybe String)
waitForAnswer doc = do
    mvAns <- newEmptyMVar

    Just ansText <- getElementById doc ("answer-text" :: String)
    Just ansBtn  <- getElementById doc ("answer-btn" :: String)
    Just skipBtn <- getElementById doc ("skip-btn" :: String)

    rec relAsk <- on ansBtn Element.click $ liftIO $ do
            Just ans' <- TextArea.getValue $ castToHTMLTextAreaElement ansText
            let ans = trim ans'
            when (not $ null $ ans) $ putMVar mvAns $ Just ans
            relAsk

    rec relBtn <- on ansText Element.keyDown $ do
            keyEvent <- ask
            kid <- getKeyIdentifier keyEvent
            ctrl <- getCtrlKey keyEvent
            when (ctrl && kid == ("Enter" :: String)) $ do
                HTMLElement.click (castToHTMLElement ansBtn)
                liftIO $ relBtn

    rec relSkip <- on skipBtn Element.click $ liftIO $ do
            putMVar mvAns Nothing
            relSkip

    ret <- takeMVar mvAns
    TextArea.setValue (castToHTMLTextAreaElement ansText) (Just ("" :: String))
    return ret

retrieveAsks :: Chan Ask -> IO ()
retrieveAsks q = go mempty
  where
    go ss = do
        -- putStrLn "retrieving asks..."
        asks <- reverse <$> getAsks
        -- putStrLn $ "got " ++ (show $ length asks) ++ " asks"

        let f db ask = do
                if Set.member (askURL ask) db
                    then return db
                    else do
                    -- P.print ("ins chan", ask)
                    writeChan q ask
                    return $ Set.insert (askURL ask) db

        ss' <- foldM f ss asks
        threadDelay (60 * 10^6)
        go ss'

askMain :: IO ()
askMain = runWebGUI $ \webView -> do
    Just doc <- webViewGetDomDocument webView

    waitForLogin doc
    -- Just loginDialog <- getElementById doc ("login-dialog" :: String)
    -- Just loginBtn <- getElementById doc ("login-btn" :: String)
    -- Just style <- getStyle loginDialog
    -- setProperty style ("visibility" :: String) (Just ("hidden" :: String)) ("" :: String)

    askQ <- newChan
    forkIO $ retrieveAsks askQ

    forever $ do
        ask <- readChan askQ
        appendAsk doc ask

        let go = do
                mbans <- waitForAnswer doc
                case mbans of
                    Nothing -> do
                        -- putStrLn $ "skip: " ++ askURL ask
                        appendAns doc "今は答える気分ではない。"
                    Just ans -> do
                        res <- putAns ask ans
                        case res of
                            Left err -> do
                                -- putStrLn $ "Send answer error: " ++ err
                                go
                            Right () ->
                                appendAns doc ans

        go
        threadDelay (10^6)

    forever $ threadDelay (10^6)