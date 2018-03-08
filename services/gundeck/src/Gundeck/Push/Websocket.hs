{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE ViewPatterns      #-}

module Gundeck.Push.Websocket (push, bulkPush) where

import Bilge
import Bilge.Retry (rpcHandlers)
import Bilge.RPC
import Control.Arrow ((&&&))
import Control.Exception (ErrorCall(ErrorCall))
import Control.Exception.Enclosed (handleAny)
import Control.Monad (forM, forM_, foldM, when)
import Control.Monad.Catch (MonadThrow, SomeException (..), throwM, catch, try)
import Control.Lens ((^.), (%~), _2, view)
import Control.Retry
import Data.Aeson (encode, eitherDecode)
import Data.ByteString.Conversion
import Data.Foldable (toList)
import Data.Function (on)
import Data.Id
import Data.List (groupBy, sortBy, foldl')
import Data.List1
import Data.Monoid ((<>))
import Data.Set (Set)
import Data.Time.Clock.POSIX
import Gundeck.Monad
import Gundeck.Types.Notification
import Gundeck.Types.BulkPush
import Gundeck.Types.Presence
import Gundeck.Util
import Network.HTTP.Client (HttpException (..), HttpExceptionContent (..))
import Network.HTTP.Types (StdMethod (POST), status200, status410)
import System.Logger.Class ((~~), val, (+++))

import qualified Data.ByteString.Lazy         as L
import qualified Data.Metrics                 as Metrics
import qualified Data.Set                     as Set
import qualified Data.Map                     as Map
import qualified Gundeck.Presence.Data        as Presence
import qualified Network.HTTP.Client.Internal as Http
import qualified System.Logger.Class          as Log

-- | Send a 'Notification's to associated 'Presence's.  Send at most one request to each Cannon.
-- Return the lists of 'Presence's successfully reached for each resp. 'Notification'.
bulkPush :: [(Notification, [Presence])] -> Gundeck [(NotificationId, [Presence])]
bulkPush notifs = do
    let reqs = fanOut notifs
    flbck <- flowBack reqs <$> (uncurry bulkSend `mapM` reqs)

    let -- lookup by 'URI' can fail iff we screwed up URI handling in this module.
        presencesByCannon = mkPresencesByCannon . mconcat $ snd <$> notifs

        -- lookup by 'PushTarget' can fail iff Cannon sends an invalid key.
        presenceByPushTarget = mkPresenceByPushTarget . mconcat $ snd <$> notifs

    cannonsGone :: [(URI, (SomeException, [Presence]))]
        <- forM (flowBackBadCannons flbck) $ \(uri, e) -> (uri,) . (e,) <$> presencesByCannon uri

    prcsGone :: [Presence]
        <- presenceByPushTarget `mapM` flowBackLostPrcs flbck

    successes :: [(NotificationId, Presence)]
        <- (\(nid, trgt) -> (nid,) <$> presenceByPushTarget trgt) `mapM` flowBackDelivered flbck

    -- TODO: should we make the log entries look different from before?  we could be a lot more
    -- concise now, and log info about lists of presences.  for now i'll leave this exactly(?) as
    -- in the old code.

    forM_ cannonsGone $ \(_uri, (_err, prcs)) -> do
        view monitor >>= Metrics.counterAdd (fromIntegral $ length prcs)
            (Metrics.path "push.ws.unreachable")
        forM_ prcs $ \prc ->
            Log.info $ logPresence prc
                ~~ Log.field "created_at" (ms $ createdAt prc)
                ~~ Log.msg (val "WebSocket presence unreachable: " +++ toByteString (resource prc))

    forM_ prcsGone $ \prc ->
        Log.debug $ logPresence prc ~~ Log.msg (val "WebSocket presence gone")

    forM_ (snd <$> successes) $ \prc ->
        Log.debug $ logPresence prc ~~ Log.msg (val "WebSocket push success")

    Presence.deleteAll =<< do
        now <- posixTime
        let deletions = prcsGone <> (filter dead . mconcat $ snd . snd <$> cannonsGone)
            dead prc  = now - createdAt prc > 10 * posixDay
            posixDay  = Ms (round (1000 * posixDayLength))
        pure deletions

    pure (groupAssoc successes)

fanOut :: [(Notification, [Presence])] -> [(URI, BulkPushRequest)]
fanOut
    = fmap (_2 %~ (mkBulkPushRequest . groupByNotification))
    . groupByURI
    . mconcat
    . fmap pullUri
  where
    mkBulkPushRequest :: [(Notification, [Presence])] -> BulkPushRequest
    mkBulkPushRequest = BulkPushRequest . fmap (_2 %~ fmap (userId &&& connId))

    groupByNotification :: [(Notification, Presence)] -> [(Notification, [Presence])]
    groupByNotification = groupAssoc' (compare `on` ntfId)

    groupByURI :: [(Notification, (URI, Presence))] -> [(URI, [(Notification, Presence)])]
    groupByURI = groupAssoc . fmap (\(notif, (uri, prc)) -> (uri, (notif, prc)))

    pullUri :: (notif, [Presence]) -> [(notif, (URI, Presence))]
    pullUri (notif, prcs) = (notif,) . (resource &&& id) <$> prcs

bulkSend :: URI -> BulkPushRequest -> Gundeck (URI, Either SomeException BulkPushResponse)
bulkSend uri req = (uri,) <$> ((Right <$> bulkSend' uri req) `catch` (pure . Left))

bulkSend' :: URI -> BulkPushRequest -> Gundeck BulkPushResponse
bulkSend' uri (encode -> jsbody) = do
    req <- Http.setUri empty (fromURI uri)
    try (submit req) >>= \case
        Left  e -> throwM (e :: SomeException)
        Right r -> decodeBulkResp $ responseBody r
  where
    submit req = recovering (limitRetries 1) rpcHandlers $ const
        (rpc' "cannon" (check req)
            ( method POST
            . contentJson
            . lbytes jsbody
            . timeout 3000 -- ms
            ))

    check req = req { Http.checkResponse = \rq rs ->
        when (responseStatus rs /= status200) $
            let ex = StatusCodeException (rs { responseBody = () }) mempty
            in throwM $ HttpExceptionRequest rq ex
    }

    decodeBulkResp :: MonadThrow m => Maybe L.ByteString -> m BulkPushResponse
    decodeBulkResp Nothing    = throwM $ ErrorCall "missing response body from cannon"
    decodeBulkResp (Just lbs) = either err pure $ eitherDecode lbs
      where err = throwM . ErrorCall . ("bad response body from cannon: " <>)

data FlowBack = FlowBack
    { flowBackBadCannons :: [(URI, SomeException)]  -- ^ list of cannons that failed to respond with status 200
    , flowBackLostPrcs   :: [PushTarget]            -- ^ 401 inside the body (for one presence)
    , flowBackDelivered  :: [(NotificationId, PushTarget)]
    }

flowBack :: [(URI, BulkPushRequest)] -> [(URI, Either SomeException BulkPushResponse)] -> FlowBack
flowBack _re99qs rawresps = FlowBack broken gone delivered
  where
    broken :: [(URI, SomeException)]
    broken
        = catLefts rawresps

    gone :: [PushTarget]  -- (may contain some values more than once.)
    gone
        = map (snd . snd)
        . filter (\(st, _) -> case st of
                     PushStatusOk   -> False
                     PushStatusGone -> True)
        $ responsive

    delivered :: [(NotificationId, PushTarget)]
    delivered
        = map snd
        . filter (\(st, _) -> case st of
                     PushStatusOk   -> True
                     PushStatusGone -> False)
        $ responsive

    responsive :: [(PushStatus, (NotificationId, PushTarget))]
    responsive = map (\(n, t, s) -> (s, (n, t)))
               . mconcat . mconcat . fmap fromBulkPushResponse . catRights $ snd <$> rawresps

    catRights :: [Either a b] -> [b]
    catRights []             = []
    catRights (Left _ : xs)  = catRights xs
    catRights (Right x : xs) = x : catRights xs

    catLefts :: [(c, Either a b)] -> [(c, a)]
    catLefts []                  = []
    catLefts ((c, Left x) : xs)  = (c, x) : catLefts xs
    catLefts ((_, Right _) : xs) = catLefts xs


{-# INLINE mkPresencesByCannon #-}
mkPresencesByCannon :: MonadThrow m => [Presence] -> URI -> m [Presence]
mkPresencesByCannon prcs uri = maybe (throwM err) pure $ Map.lookup uri mp
  where
    err = ErrorCall "internal error in Gundeck: invalid URL in bulkpush result"

    mp :: Map.Map URI [Presence]
    mp = foldl' collect mempty $ (resource &&& id) <$> prcs

    collect :: Map.Map URI [Presence] -> (URI, Presence) -> Map.Map URI [Presence]
    collect mp' (uri', prc) = Map.alter (go prc) uri' mp'

    go :: Presence -> Maybe [Presence] -> Maybe [Presence]
    go prc Nothing = Just [prc]
    go prc (Just prcs') = Just $ prc : prcs'


{-# INLINE mkPresenceByPushTarget #-}
mkPresenceByPushTarget :: MonadThrow m => [Presence] -> PushTarget -> m Presence
mkPresenceByPushTarget prcs ptarget = maybe (throwM err) pure $ Map.lookup ptarget mp
  where
    err = ErrorCall "internal error in Cannon: invalid PushTarget in bulkpush response"

    mp :: Map.Map PushTarget Presence
    mp = Map.fromList $ ((userId &&& connId) &&& id) <$> prcs


-- TODO: a Map-based implementation would be faster.  do we want to take the time and benchmark the
-- difference?
{-# INLINE groupAssoc #-}
groupAssoc :: (Eq a, Ord a) => [(a, b)] -> [(a, [b])]
groupAssoc = groupAssoc' compare

-- TODO: Also should we give 'Notification' an 'Ord' instance?
{-# INLINE groupAssoc' #-}
groupAssoc' :: (Eq a) => (a -> a -> Ordering) -> [(a, b)] -> [(a, [b])]
groupAssoc' cmp = fmap (\case
                    xs@(x : _) -> (fst x, snd <$> xs)
                    [] -> error "impossible: list elements returned by groupBy are never empty.")
           . groupBy ((==) `on` fst)
           . sortBy (cmp `on` fst)



-- TODO: testing is easy: just set the config flag.  (-: (we should look at the integration tests
-- though and see if we need to add anything.)



-----------------------------------------------------------------------------
-- old, multi-request push.

push :: Notification
     -> List1 NotificationTarget
     -> UserId -- Origin user.
     -> Maybe ConnId -- Origin device connection.
     -> Set ConnId -- Only target these connections.
     -> Gundeck [Presence]
push notif (toList -> tgts) originUser originConn conns = do
    pp <- handleAny noPresences listPresences
    (ok, gone) <- foldM onResult ([], []) =<< send notif pp
    Presence.deleteAll gone
    return ok
  where
    listPresences = excludeOrigin
                  . filterByConnection
                  . concat
                  . filterByClient
                  . zip tgts
                 <$> Presence.listAll (view targetUser <$> tgts)

    noPresences exn = do
        Log.err $ Log.field "error" (show exn)
               ~~ Log.msg (val "Failed to get presences.")
        return []

    filterByClient = map $ \(tgt, ps) -> let cs = tgt^.targetClients in
        if null cs then ps
        else filter (maybe True (`elem` cs) . clientId) ps

    filterByConnection =
        if Set.null conns then id
        else filter ((`Set.member` conns) . connId)

    excludeOrigin =
        let
            neqUser p = originUser /= userId p
            neqConn p = originConn /= Just (connId p)
        in
            filter (\p -> neqUser p || neqConn p)

    onResult (ok, gone) (PushSuccess p) = do
        Log.debug $ logPresence p ~~ Log.msg (val "WebSocket push success")
        return (p:ok, gone)

    onResult (ok, gone) (PushGone p) = do
        Log.debug $ logPresence p ~~ Log.msg (val "WebSocket presence gone")
        return (ok, p:gone)

    onResult (ok, gone) (PushFailure p _) = do
        view monitor >>= Metrics.counterIncr (Metrics.path "push.ws.unreachable")
        Log.info $ logPresence p
            ~~ Log.field "created_at" (ms $ createdAt p)
            ~~ Log.msg (val "WebSocket presence unreachable: " +++ toByteString (resource p))
        now <- posixTime
        if now - createdAt p > 10 * posixDay
           then return (ok, p:gone)
           else return (ok, gone)

    posixDay = Ms (round (1000 * posixDayLength))

-----------------------------------------------------------------------------
-- Internal

-- | Not to be confused with 'PushStatus': 'PushResult' is in internal to Gundeck, carries a
-- 'Presence', and can express HTTP errors.
data PushResult
    = PushSuccess Presence
    | PushGone    Presence
    | PushFailure Presence SomeException

send :: Notification -> [Presence] -> Gundeck [PushResult]
send n pp =
    let js = encode n in
    zipWith eval pp <$> mapAsync (fn js) pp
  where
    fn js p = do
        req <- Http.setUri empty (fromURI (resource p))
        recovering x1 rpcHandlers $ const $
            rpc' "cannon" (check req)
                $ method POST
                . contentJson
                . lbytes js
                . timeout 3000 -- ms

    check r = r { Http.checkResponse = \rq rs ->
        when (responseStatus rs `notElem` [status200, status410]) $
            let ex = StatusCodeException (rs { responseBody = () }) mempty
            in throwM $ HttpExceptionRequest rq ex
    }

    eval p (Left  e) = PushFailure p e
    eval p (Right r) = if statusCode r == 200 then PushSuccess p else PushGone p

    x1 = limitRetries 1

logPresence :: Presence -> Log.Msg -> Log.Msg
logPresence p =
       Log.field "user"   (toByteString (userId p))
    ~~ Log.field "zconn"  (toByteString (connId p))
